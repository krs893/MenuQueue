import Foundation

// MARK: - Models

struct MusicTrack: Codable, Hashable, Identifiable {
    var id: String { "\(databaseID)" }
    var databaseID: Int
    var name: String
    var artist: String
    var album: String
    var duration: Double
    var sourcePlaylistID: String? = nil
    /// Seconds since the epoch, as Music reports "date added". Only the
    /// ordering matters, so the timezone offset baked into it is harmless —
    /// it is the same constant for every track.
    var addedAt: Double = 0

    var subtitle: String {
        [artist, album].filter { !$0.isEmpty }.joined(separator: " — ")
    }
}

struct PlaylistInfo: Identifiable, Hashable {
    var id: String          // persistent ID
    var name: String
    var count: Int
}

enum PlayerState: String {
    case stopped, playing, paused, fastForwarding = "fast forwarding", rewinding
    case unknown

    init(appleScript raw: String) {
        self = PlayerState(rawValue: raw.trimmingCharacters(in: .whitespaces)) ?? .unknown
    }
    var isPlaying: Bool { self == .playing || self == .fastForwarding || self == .rewinding }
}

struct NowPlaying {
    var state: PlayerState = .stopped
    var track: MusicTrack?
    var position: Double = 0
    var shuffle: Bool = false
    var repeatMode: String = "off"
    var volume: Int = 100
    var muted: Bool = false
}


/// Music offers Add to Queue when an explicit queue exists, and Play Next
/// when creating one. Both insert a whole playlist without replacing playback.
enum QueueInsertionPosition: Equatable {
    case end, next

    static func menuChoice(_ titles: [String]) -> (index: Int, position: Self)? {
        let normalized = titles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        for name in ["キューに追加", "最後に再生", "あとで再生", "add to queue", "play last", "play later"] {
            if let index = normalized.firstIndex(of: name) { return (index, .end) }
        }
        for name in ["次に再生", "play next"] {
            if let index = normalized.firstIndex(of: name) { return (index, .next) }
        }
        return nil
    }
}
