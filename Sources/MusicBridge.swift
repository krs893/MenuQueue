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

    struct ScriptError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

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
                if cache.count >= 128 { cache.removeAll(keepingCapacity: true) }
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
        set AppleScript's text item delimiters to (character id 29)
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
            set mqMute to ((mute) as text)
        end tell
        return my joinList({mqState, mqID, mqName, mqArtist, mqAlbum, mqDur, mqPos, mqShuffle, mqRepeat, mqVol, mqMute})
        """
        let raw = try ScriptRunner.shared.string(src)
        let f = raw.components(separatedBy: RS)
        guard f.count >= 10 else { return NowPlaying() }

        var np = NowPlaying()
        np.state = PlayerState(appleScript: f[0])
        let dbID = Int(f[1]) ?? 0
        if dbID != 0 {
            np.track = MusicTrack(databaseID: dbID, name: f[2], artist: f[3],
                                  album: f[4], duration: number(f[5]))
        }
        np.position = number(f[6])
        np.shuffle = (f[7] == "true")
        np.repeatMode = f[8]
        np.volume = Int(Double(f[9]) ?? 100)
        np.muted = f.count > 10 && f[10] == "true"
        return np
    }

    /// Artwork for a specific library track. Resolved the same way playback is:
    /// cloud tracks only exist inside their own playlist, never in the library
    /// playlist, so the container has to come with the id.
    static func artwork(databaseID: Int, playlistID: String?) -> NSImage? {
        let pid = esc(playlistID ?? "")
        let container = playlistID == nil
            ? "library playlist 1"
            : "(first user playlist whose persistent ID is \"\(pid)\")"
        let src = """
        tell application id "com.apple.Music"
            try
                set mqMatches to (every track of \(container) whose database ID is \(databaseID))
                if mqMatches is {} then return missing value
                return raw data of artwork 1 of (item 1 of mqMatches)
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
    static func play(databaseID: Int, playlistID: String? = nil, validateOnly: Bool = false) throws -> Bool {
        let pid = esc(playlistID ?? "")
        let shouldPlay = validateOnly ? "false" : "true"
        let src = """
        tell application id "com.apple.Music"
            set mqMatches to {}
            if "\(pid)" is not "" then
                try
                    set mqSource to first user playlist whose persistent ID is "\(pid)"
                    set mqMatches to (every track of mqSource whose database ID is \(databaseID))
                end try
            end if
            if mqMatches is {} then
                set mqMatches to (every track of library playlist 1 whose database ID is \(databaseID))
            end if
            if mqMatches is {} then
                repeat with mqSource in (every user playlist)
                    try
                        set mqMatches to (every track of mqSource whose database ID is \(databaseID))
                    end try
                    if mqMatches is not {} then exit repeat
                end repeat
            end if
            if mqMatches is {} then return "notfound"
            if \(shouldPlay) then play (item 1 of mqMatches)
            return "ok"
        end tell
        """
        return try ScriptRunner.shared.string(src) == "ok"
    }

    /// No longer reachable from the UI: driving Music's toolbar menu through
    /// Accessibility cannot work on macOS 26, where that toolbar reports no
    /// children at all. Kept so the existing tests still describe the path.
    static func enqueuePlaylist(_ id: String) throws -> QueueInsertionPosition {
        try UpNextReader.enqueuePlaylist(id)
    }

    static func playPlaylist(_ persistentID: String) throws {
        let pid = esc(persistentID)
        let src = """
        tell application id "com.apple.Music"
            set mqPlaylist to first user playlist whose persistent ID is "\(pid)"
            play mqPlaylist
        end tell
        """
        try ScriptRunner.shared.run(src)
    }


    static func revealPlaylist(_ persistentID: String) throws {
        let pid = esc(persistentID)
        try ScriptRunner.shared.run("""
        tell application id "com.apple.Music"
            reveal (first user playlist whose persistent ID is "\(pid)")
        end tell
        """)
    }

    /// The playlist currently shown in Music's browser window, or "" when the
    /// window is showing something without one — Home, a store page, or no
    /// window at all. Coercing that to text throws a type error, which used to
    /// abort the whole enqueue with a misleading message.
    static func displayedPlaylistID() throws -> String {
        try ScriptRunner.shared.string("""
        tell application id "com.apple.Music"
            try
                set mqView to (view of front browser window)
                set mqID to (persistent ID of mqView)
                if mqID is missing value then return ""
                return (mqID as text)
            on error
                return ""
            end try
        end tell
        """)
    }

    // MARK: Library browsing

    static func search(_ query: String, limit: Int = 60) throws -> [MusicTrack] {
        let q = esc(query)
        guard !q.isEmpty else { return [] }
        let src = joinHandler + """
        tell application id "com.apple.Music"
            set mqOut to {}
            set mqRes to (search library playlist 1 for "\(q)" only songs)
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
        // Folders are kept, not filtered out, and each entry carries the folder
        // it belongs to so the panel can show the structure the user built.
        // `parent` has to be asked for one playlist at a time — it errors for
        // anything at the top level — but there are only a couple of dozen.
        let src = joinHandler + """
        tell application id "com.apple.Music"
            set mqOut to {}
            -- Folders are their own class and do NOT appear in `every user
            -- playlist`; they surface only as someone's parent. Enumerate them
            -- separately or the structure is invisible.
            repeat with mqFolder in (every folder playlist)
                try
                    set mqParent to ""
                    try
                        set mqParent to (persistent ID of (parent of mqFolder))
                    end try
                    set end of mqOut to my joinList({(persistent ID of mqFolder), (name of mqFolder), "0", mqParent, "1"})
                end try
            end repeat
            repeat with mqPL in (every user playlist)
                try
                    set mqIsFolder to "0"
                    set mqCount to "0"
                    try
                        set mqCount to ((count of tracks of mqPL) as text)
                    end try
                    set mqParent to ""
                    try
                        set mqParent to (persistent ID of (parent of mqPL))
                    end try
                    set end of mqOut to my joinList({(persistent ID of mqPL), (name of mqPL), mqCount, mqParent, mqIsFolder})
                end try
            end repeat
        end tell
        return my joinLines(mqOut)
        """
        let raw = try ScriptRunner.shared.string(src)
        return raw.split(separator: "\u{1D}").compactMap { line in
            let f = String(line).components(separatedBy: RS)
            guard f.count >= 3 else { return nil }
            return PlaylistInfo(id: f[0], name: f[1], count: Int(f[2]) ?? 0,
                                parentID: f.count > 3 && !f[3].isEmpty ? f[3] : nil,
                                isFolder: f.count > 4 && f[4] == "1")
        }
    }

    static func tracks(inPlaylist persistentID: String) throws -> [MusicTrack] {
        let pid = esc(persistentID)
        // Fetch columns in bulk: five Music events regardless of playlist size.
        // The join loop below operates entirely on local AppleScript lists.
        let src = joinHandler + """
        tell application id "com.apple.Music"
            -- Bulk property access throws on an empty playlist: `every track`
            -- returns {} but `database ID of every track` fails. Answer with
            -- empty lists so an empty (often smart) playlist is not an error.
            set mqPL to (first user playlist whose persistent ID is "\(pid)")
            if (count of tracks of mqPL) is 0 then
                set mqIDs to {}
                set mqNames to {}
                set mqArtists to {}
                set mqAlbums to {}
                set mqDurations to {}
            else
                            set mqIDs to database ID of every track of mqPL
            set mqNames to name of every track of mqPL
            set mqArtists to artist of every track of mqPL
            set mqAlbums to album of every track of mqPL
            set mqDurations to duration of every track of mqPL
            end if
        end tell
        set mqOut to {}
        repeat with mqI from 1 to (count of mqIDs)
            set end of mqOut to my joinList({item mqI of mqIDs, item mqI of mqNames, item mqI of mqArtists, item mqI of mqAlbums, item mqI of mqDurations})
        end repeat
        return my joinLines(mqOut)
        """
        return parseTracks(try ScriptRunner.shared.string(src)).map {
            var track = $0
            track.sourcePlaylistID = persistentID
            return track
        }
    }

    private static func number(_ text: String) -> Double {
        Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private static func parseTracks(_ raw: String) -> [MusicTrack] {
        raw.split(separator: "\u{1D}").compactMap { line in
            let f = String(line).components(separatedBy: RS)
            guard f.count >= 5, let id = Int(f[0]) else { return nil }
            return MusicTrack(databaseID: id, name: f[1], artist: f[2],
                              album: f[3], duration: number(f[4]))
        }
    }
}
