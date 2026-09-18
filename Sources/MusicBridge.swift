import Foundation
import AppKit

// MARK: - AppleScript runner
// NSAppleScript is not thread-safe, so every call is funnelled through one
// serial queue. Compiled scripts are cached because the polling loop reuses
// the same sources once a second.

final class ScriptRunner {
    static let shared = ScriptRunner()
    private let queue = DispatchQueue(label: "jp.menuqueue.applescript")
    private var cache: [String: NSAppleScript] = [:]

    struct ScriptError: Error { let message: String }

    @discardableResult
    func run(_ source: String) throws -> NSAppleEventDescriptor {
        try queue.sync {
            let script: NSAppleScript
            if let cached = cache[source] {
                script = cached
            } else {
                guard let s = NSAppleScript(source: source) else {
                    throw ScriptError(message: "script could not be created")
                }
                cache[source] = s
                script = s
            }
            var err: NSDictionary?
            let result = script.executeAndReturnError(&err)
            if let err {
                let msg = (err[NSAppleScript.errorMessage] as? String) ?? "unknown AppleScript error"
                let num = (err[NSAppleScript.errorNumber] as? Int).map { " (\($0))" } ?? ""
                throw ScriptError(message: msg + num)
            }
            return result
        }
    }

    func string(_ source: String) throws -> String {
        try run(source).stringValue ?? ""
    }
}

// MARK: - Models

struct MusicTrack: Codable, Hashable, Identifiable {
    var id: String { "\(databaseID)" }
    var databaseID: Int
    var name: String
    var artist: String
    var album: String
    var duration: Double

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

// MARK: - Music.app bridge

enum MusicBridge {

    static let bundleID = "com.apple.Music"
    /// Record separator — safer than tab, which can legitimately appear in tags.
    private static let RS = "\u{1E}"

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static let joinHandler = """
    on joinList(lst)
        set od to AppleScript's text item delimiters
        set AppleScript's text item delimiters to (character id 30)
        set s to lst as text
        set AppleScript's text item delimiters to od
        return s
    end joinList

    on joinLines(lst)
        set od to AppleScript's text item delimiters
        set AppleScript's text item delimiters to linefeed
        set s to lst as text
        set AppleScript's text item delimiters to od
        return s
    end joinLines

    """

    // MARK: Reading state

    static func nowPlaying() throws -> NowPlaying {
        guard isRunning else { return NowPlaying() }
        let src = joinHandler + """
        tell application id "com.apple.Music"
            set mqState to (player state as text)
            set mqID to "0"
            set mqName to ""
            set mqArtist to ""
            set mqAlbum to ""
            set mqDur to "0"
            set mqPos to "0"
            try
                set mqTrack to current track
                set mqID to ((database ID of mqTrack) as text)
                set mqName to (name of mqTrack)
                set mqArtist to (artist of mqTrack)
                set mqAlbum to (album of mqTrack)
                set mqDur to ((duration of mqTrack) as text)
            end try
            try
                set mqPos to ((player position) as text)
            end try
            set mqShuffle to ((shuffle enabled) as text)
            set mqRepeat to ((song repeat) as text)
            set mqVol to ((sound volume) as text)
        end tell
        return my joinList({mqState, mqID, mqName, mqArtist, mqAlbum, mqDur, mqPos, mqShuffle, mqRepeat, mqVol})
        """
        let raw = try ScriptRunner.shared.string(src)
        let f = raw.components(separatedBy: RS)
        guard f.count >= 10 else { return NowPlaying() }

        var np = NowPlaying()
        np.state = PlayerState(appleScript: f[0])
        let dbID = Int(f[1]) ?? 0
        if dbID != 0 {
            np.track = MusicTrack(databaseID: dbID, name: f[2], artist: f[3],
                                  album: f[4], duration: Double(f[5]) ?? 0)
        }
        np.position = Double(f[6]) ?? 0
        np.shuffle = (f[7] == "true")
        np.repeatMode = f[8]
        np.volume = Int(Double(f[9]) ?? 100)
        return np
    }

    static func artworkOfCurrentTrack() -> NSImage? {
        guard isRunning else { return nil }
        let src = """
        tell application id "com.apple.Music"
            try
                return raw data of artwork 1 of current track
            on error
                return missing value
            end try
        end tell
        """
        guard let desc = try? ScriptRunner.shared.run(src) else { return nil }
        let data = desc.data
        guard data.count > 16 else { return nil }
        return NSImage(data: data)
    }

    // MARK: Transport

    private static func tellMusic(_ body: String) throws {
        try ScriptRunner.shared.run("tell application id \"com.apple.Music\"\n\(body)\nend tell")
    }

    static func playPause() throws { try tellMusic("playpause") }
    static func pause()     throws { try tellMusic("pause") }
    static func resume()    throws { try tellMusic("play") }
    static func nativeNext()  throws { try tellMusic("next track") }
    static func nativePrev()  throws { try tellMusic("back track") }
    static func stop()      throws { try tellMusic("stop") }

    static func seek(to seconds: Double) throws {
        try tellMusic("set player position to \(seconds)")
    }
    static func setVolume(_ v: Int) throws {
        try tellMusic("set sound volume to \(max(0, min(100, v)))")
    }
    static func setShuffle(_ on: Bool) throws {
        try tellMusic("set shuffle enabled to \(on)")
    }
    /// mode: off | one | all
    static func setRepeat(_ mode: String) throws {
        try tellMusic("set song repeat to \(mode)")
    }

    /// Plays a library track identified by its database ID.
    @discardableResult
    static func play(databaseID: Int) throws -> Bool {
        let src = """
        tell application id "com.apple.Music"
            set mqMatches to (every track of library playlist 1 whose database ID is \(databaseID))
            if mqMatches is {} then return "notfound"
            play (item 1 of mqMatches)
            return "ok"
        end tell
        """
        return try ScriptRunner.shared.string(src) == "ok"
    }

    // MARK: Library browsing

    static func search(_ query: String, limit: Int = 60) throws -> [MusicTrack] {
        let q = esc(query)
        guard !q.isEmpty else { return [] }
        let src = joinHandler + """
        tell application id "com.apple.Music"
            set mqOut to {}
            try
                set mqRes to (search library playlist 1 for "\(q)" only songs)
            on error
                set mqRes to {}
            end try
            set mqCount to (count of mqRes)
            if mqCount > \(limit) then set mqCount to \(limit)
            repeat with mqI from 1 to mqCount
                set mqTrack to item mqI of mqRes
                try
                    set end of mqOut to my joinList({((database ID of mqTrack) as text), (name of mqTrack), (artist of mqTrack), (album of mqTrack), ((duration of mqTrack) as text)})
                end try
            end repeat
        end tell
        return my joinLines(mqOut)
        """
        return parseTracks(try ScriptRunner.shared.string(src))
    }

    static func playlists() throws -> [PlaylistInfo] {
        let src = joinHandler + """
        tell application id "com.apple.Music"
            set mqOut to {}
            repeat with mqPL in (every user playlist)
                try
                    if (class of mqPL) is not folder playlist then
                        set end of mqOut to my joinList({(persistent ID of mqPL), (name of mqPL), ((count of tracks of mqPL) as text)})
                    end if
                end try
            end repeat
        end tell
        return my joinLines(mqOut)
        """
        let raw = try ScriptRunner.shared.string(src)
        return raw.split(separator: "\n").compactMap { line in
            let f = String(line).components(separatedBy: RS)
            guard f.count >= 3 else { return nil }
            return PlaylistInfo(id: f[0], name: f[1], count: Int(f[2]) ?? 0)
        }
    }

    static func tracks(inPlaylist persistentID: String, limit: Int = 500) throws -> [MusicTrack] {
        let pid = esc(persistentID)
        let src = joinHandler + """
        tell application id "com.apple.Music"
            set mqOut to {}
            try
                set mqPL to (first user playlist whose persistent ID is "\(pid)")
                set mqRes to (every track of mqPL)
                set mqCount to (count of mqRes)
                if mqCount > \(limit) then set mqCount to \(limit)
                repeat with mqI from 1 to mqCount
                    set mqTrack to item mqI of mqRes
                    try
                        set end of mqOut to my joinList({((database ID of mqTrack) as text), (name of mqTrack), (artist of mqTrack), (album of mqTrack), ((duration of mqTrack) as text)})
                    end try
                end repeat
            end try
        end tell
        return my joinLines(mqOut)
        """
        return parseTracks(try ScriptRunner.shared.string(src))
    }

    private static func parseTracks(_ raw: String) -> [MusicTrack] {
        raw.split(separator: "\n").compactMap { line in
            let f = String(line).components(separatedBy: RS)
            guard f.count >= 5, let id = Int(f[0]) else { return nil }
            return MusicTrack(databaseID: id, name: f[1], artist: f[2],
                              album: f[3], duration: Double(f[4]) ?? 0)
        }
    }
}
