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

enum MusicBridge {
    static let bundleID = "com.apple.Music"
    static var isRunning = true
    static var snapshot = NowPlaying()
    static var repeatWrites: [String] = []
    static var plays: [Int] = []
    static var missing = false
    static var nativeNextCount = 0
    static var lastPlaylist: String?
    static func playPlaylist(_ id: String) throws { lastPlaylist = id; snapshot.state = .playing }
    static var delay: Double = 0
    static var readDelay: Double = 0
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
        let captured = snapshot
        let wait = readDelay
        readStarted.signal()
        Thread.sleep(forTimeInterval: wait)
        return captured
    }
    static func artworkOfCurrentTrack() -> NSImage? { nil }
    static func setRepeat(_ mode: String) throws { repeatWrites.append(mode); snapshot.repeatMode = mode }
    static func play(databaseID: Int, playlistID: String? = nil) throws -> Bool {
        Thread.sleep(forTimeInterval: delay)
        guard !missing else { return false }
        plays.append(databaseID)
        snapshot.track = MusicTrack(databaseID: databaseID, name: "Track", artist: "", album: "", duration: 100)
        snapshot.position = 0
        snapshot.state = .playing
        return true
    }
    static func pause() throws { snapshot.state = .paused }
    static func playPause() throws { snapshot.state = snapshot.state.isPlaying ? .paused : .playing }
    static func seek(to value: Double) throws { snapshot.position = value }
    static func setVolume(_ value: Int) throws { snapshot.volume = value }
    static func setShuffle(_ value: Bool) throws {
        let wait = shuffleDelay
        let fail = failShuffle
        shuffleStarted.signal()
        Thread.sleep(forTimeInterval: wait)
        if fail { throw TestError.shuffleFailed }
        shuffleWrites.append(value)
        snapshot.shuffle = value
    }
    static func nativeNext() throws { nativeNextCount += 1 }
    static func nativePrev() throws {}
}
