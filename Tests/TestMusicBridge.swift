import Foundation
import AppKit

// This executable substitutes the Music adapter so regression checks cannot
// change the user's actual playback, library, volume or repeat mode.
final class TestSignal {
    private let lock = NSLock()
    private var pending = 0
    func signal() { lock.lock(); defer { lock.unlock() }; pending += 1 }
    // Nonblocking observation, safe to call from the main actor.
    func consume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pending > 0 else { return false }
        pending -= 1
        return true
    }
}

// LibraryIndex drives AppleScript directly rather than through MusicBridge,
// so it needs its own stub: the regression run must never read the real
// library or depend on what happens to be in it.
final class ScriptRunner {
    static let shared = ScriptRunner()
    static var canned = ""
    static var calls = 0
    func string(_ source: String) throws -> String {
        Self.calls += 1
        return Self.canned
    }
}

enum MusicBridge {
    static let bundleID = "com.apple.Music"
    static var isRunning = true
    static var snapshot = NowPlaying()
    static var repeatWrites: [String] = []
    static var plays: [Int] = []
    static var missing = false
    static var nativeNextCount = 0
    static var lastPlaylist: String?
    static var nativePlaylistContext = ""
    static var failPlaylistContextRead = false
    static func currentPlaylistID() throws -> String {
        if failPlaylistContextRead { throw TestError.queueAddFailed }
        return nativePlaylistContext
    }
    static func playPlaylist(_ id: String) throws {
        lastPlaylist = id
        snapshot.state = .playing
        snapshot.repeatMode = "all"
    }
    static var delay: Double = 0
    static var readDelay: Double = 0
    static var stateReadCount = 0
    static var failRead = false
    static var shuffleDelay: Double = 0
    static var shuffleWrites: [Bool] = []
    static var failShuffle = false
    static let shuffleStarted = TestSignal()
    static let readStarted = TestSignal()
    enum TestError: Error { case shuffleFailed, queueAddFailed }
    static var enqueuedPlaylists: [String] = []
    static var failQueueAdd = false
    static func enqueuePlaylist(_ id: String) throws -> QueueInsertionPosition {
        if failQueueAdd { throw TestError.queueAddFailed }
        enqueuedPlaylists.append(id)
        return .end
    }
    static func nowPlaying() throws -> NowPlaying {
        stateReadCount += 1
        if failRead { throw TestError.queueAddFailed }
        let captured = snapshot
        let wait = readDelay
        readStarted.signal()
        Thread.sleep(forTimeInterval: wait)
        return captured
    }
    static var currentArtwork: NSImage?
    static var artworkGate: DispatchSemaphore?
    static let artworkStarted = TestSignal()
    static var currentArtworkFetches = 0
    static func artworkOfCurrentTrack() -> NSImage? {
        currentArtworkFetches += 1
        let image = currentArtwork
        let gate = artworkGate
        artworkStarted.signal()
        _ = gate?.wait(timeout: .now() + 5)
        return image
    }
    static var artworkRequests: [Int] = []
    static func artwork(databaseID: Int, playlistID: String?) -> NSImage? {
        artworkRequests.append(databaseID)
        return nil
    }
    static func setRepeat(_ mode: String) throws { repeatWrites.append(mode); snapshot.repeatMode = mode }
    static func play(databaseID: Int, playlistID: String? = nil) throws -> Bool {
        Thread.sleep(forTimeInterval: delay)
        guard !missing else { return false }
        plays.append(databaseID)
        // Real Music resets the repeat mode when a track is started.
        snapshot.repeatMode = "off"
        snapshot.track = MusicTrack(databaseID: databaseID, name: "Track", artist: "", album: "", duration: 100)
        snapshot.position = 0
        snapshot.state = .playing
        return true
    }
    static func pause() throws { snapshot.state = .paused }
    static func playPause() throws { snapshot.state = snapshot.state.isPlaying ? .paused : .playing }
    static var seekWrites: [Double] = []
    static func seek(to value: Double) throws { seekWrites.append(value); snapshot.position = value }
    static func setVolume(_ value: Int) throws { volumeWrites.append(value); snapshot.volume = value }
    static var volumeWrites: [Int] = []
    static func setShuffle(_ value: Bool) throws {
        let wait = shuffleDelay
        let fail = failShuffle
        shuffleStarted.signal()
        Thread.sleep(forTimeInterval: wait)
        if fail { throw TestError.shuffleFailed }
        shuffleWrites.append(value)
        snapshot.shuffle = value
    }
    static var stubPlaylists: [PlaylistInfo] = []
    static var stubTracks: [String: [MusicTrack]] = [:]
    static func playlists() throws -> [PlaylistInfo] { stubPlaylists }
    static var trackReadCount = 0
    static func tracks(inPlaylist id: String) throws -> [MusicTrack] {
        trackReadCount += 1
        return stubTracks[id] ?? []
    }
    static func nativeNext() throws { nativeNextCount += 1 }
    static var shuffledPlaylists: [String] = []
    static func shufflePlaylist(_ id: String) throws {
        guard !(stubTracks[id] ?? []).isEmpty else { throw TestError.queueAddFailed }
        shuffledPlaylists.append(id)
        snapshot.state = .playing
        snapshot.shuffle = true
        snapshot.repeatMode = "all"
    }
    static var nativePrevCount = 0
    static func nativePrev() throws { nativePrevCount += 1 }
}
