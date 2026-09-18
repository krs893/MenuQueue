import Foundation
import AppKit

// This executable substitutes the Music adapter so regression checks cannot
// change the user's actual playback, library, volume or repeat mode.
enum MusicBridge {
    static let bundleID = "com.apple.Music"
    static var isRunning = true
    static var snapshot = NowPlaying()
    static var repeatWrites: [String] = []
    static var plays: [Int] = []
    static var missing = false
    static var nativeNextCount = 0
    static var delay: Double = 0
    static func nowPlaying() throws -> NowPlaying { snapshot }
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
    static func setShuffle(_ value: Bool) throws { snapshot.shuffle = value }
    static func nativeNext() throws { nativeNextCount += 1 }
    static func nativePrev() throws {}
}
