import Foundation

/// One polling result. Empty optional columns mean the script reused a cache;
/// track identity is still checked before any newly read metadata is trusted.
struct MusicStatusPayload {
    struct Settings: Equatable {
        let shuffle: Bool
        let repeatMode: String
        let volume: Int
        let muted: Bool
    }

    struct InvalidPayload: LocalizedError {
        var errorDescription: String? { "ミュージックの再生情報を読み取れませんでした" }
    }

    let state: PlayerState
    let databaseID: Int
    let position: Double
    let metadata: MusicTrack?
    let settings: Settings?

    init(_ raw: String) throws {
        let fields = raw.components(separatedBy: "\u{1E}")
        guard fields.count == 12, let databaseID = Int(fields[1]),
              let metadataID = Int(fields[3]) else { throw InvalidPayload() }
        self.state = PlayerState(appleScript: fields[0])
        self.databaseID = databaseID
        self.position = Self.number(fields[2])
        if databaseID != 0, metadataID == databaseID {
            metadata = MusicTrack(databaseID: databaseID, name: fields[4], artist: fields[5],
                                  album: fields[6], duration: Self.number(fields[7]))
        } else {
            metadata = nil
        }
        if fields[8].isEmpty {
            settings = nil
        } else {
            guard ["true", "false"].contains(fields[8]),
                  ["off", "all", "one"].contains(fields[9]),
                  ["true", "false"].contains(fields[11]) else { throw InvalidPayload() }
            settings = Settings(shuffle: fields[8] == "true", repeatMode: fields[9],
                                volume: Int(Self.number(fields[10])), muted: fields[11] == "true")
        }
    }

    private static func number(_ value: String) -> Double {
        let number = Double(value.replacingOccurrences(of: ",", with: ".")) ?? 0
        return number.isFinite ? number : 0
    }

    func track(reusing cached: MusicTrack?) -> MusicTrack? {
        guard databaseID != 0 else { return nil }
        if let metadata { return metadata }
        if cached?.databaseID == databaseID { return cached }
        // Retain the reported identity while Music is switching tracks, but
        // never cache this placeholder: the next poll must retry metadata.
        return MusicTrack(databaseID: databaseID, name: "", artist: "", album: "", duration: 0)
    }
}

/// Metadata is read only on a track change; settings every third poll or after
/// a write. A write invalidating the cache while a read is in flight must not
/// let that older read mark its old settings as fresh again.
final class MusicStatusCache {
    struct Request {
        let track: MusicTrack?
        let settings: MusicStatusPayload.Settings?
        let settingsDue: Bool
        fileprivate let settingsGeneration: UInt64
        fileprivate let sequence: UInt64
        var cachedTrackID: Int { track?.databaseID ?? 0 }
    }

    private let lock = NSLock()
    private var cachedTrack: MusicTrack?
    private var cachedSettings: MusicStatusPayload.Settings?
    private var pollsSinceSettings = 0
    private var settingsGeneration: UInt64 = 0
    private var sequence: UInt64 = 0
    private var appliedSequence: UInt64 = 0

    func invalidateSettings() {
        lock.lock(); defer { lock.unlock() }
        cachedSettings = nil
        settingsGeneration &+= 1
    }

    func beginRead() -> Request {
        lock.lock(); defer { lock.unlock() }
        sequence &+= 1
        pollsSinceSettings += 1
        return Request(track: cachedTrack, settings: cachedSettings,
                       settingsDue: cachedSettings == nil || pollsSinceSettings >= 3,
                       settingsGeneration: settingsGeneration, sequence: sequence)
    }

    func finish(_ payload: MusicStatusPayload, for request: Request) -> NowPlaying {
        let track = payload.track(reusing: request.track)
        let settings = payload.settings ?? request.settings
        lock.lock()
        if request.sequence >= appliedSequence {
            appliedSequence = request.sequence
            if payload.databaseID == 0 {
                cachedTrack = nil
            } else if let track, !track.name.isEmpty, track.duration > 0 {
                cachedTrack = track
            }
            if request.settingsGeneration == settingsGeneration, let settings = payload.settings {
                cachedSettings = settings
                pollsSinceSettings = 0
            }
        }
        lock.unlock()

        var result = NowPlaying()
        result.state = payload.state
        result.track = track
        result.position = payload.position
        if let settings {
            result.shuffle = settings.shuffle
            result.repeatMode = settings.repeatMode
            result.volume = settings.volume
            result.muted = settings.muted
        }
        return result
    }

    /// The closure executes exactly once even on a cold cache or track change.
    func read(_ execute: (Request) throws -> String) throws -> NowPlaying {
        let request = beginRead()
        return finish(try MusicStatusPayload(execute(request)), for: request)
    }
}
