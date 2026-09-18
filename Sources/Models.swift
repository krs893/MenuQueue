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
}

