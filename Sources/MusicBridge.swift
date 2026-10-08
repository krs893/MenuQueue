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

    /// When the call currently running on the queue began, nil when idle.
    ///
    /// A single Apple Event that Music never answers blocks this queue for
    /// good — NSAppleScript waited days on one artwork request, past the
    /// AppleScript default timeout — and every later call queues up behind
    /// it. The call itself cannot be cancelled, but the app can at least see
    /// that it has happened and say so instead of spinning forever.
    private let inFlightLock = NSLock()
    private var inFlightSince: Date?

    var stalledSeconds: TimeInterval {
        inFlightLock.lock(); defer { inFlightLock.unlock() }
        return inFlightSince.map { Date().timeIntervalSince($0) } ?? 0
    }

    @discardableResult
    func run(_ source: String) throws -> NSAppleEventDescriptor {
        try queue.sync {
            inFlightLock.lock(); inFlightSince = Date(); inFlightLock.unlock()
            defer { inFlightLock.lock(); inFlightSince = nil; inFlightLock.unlock() }
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

    // MARK: Now playing, cheaply
    //
    // Music takes about 35 ms to answer each Apple Event, and the old query
    // asked a dozen questions every poll — around 300 ms, polled up to ten
    // times a second near the end of a track. Most of those answers do not
    // change from one poll to the next. So each poll now asks only what does
    // (state, track id, position); the track's name, artist, album and length
    // are fetched when the id changes, and the player settings every third poll
    // or straight after this app changes one.

    private static let cacheLock = NSLock()
    private static var cachedTrack: MusicTrack?
    private static var cachedSettings: (shuffle: Bool, repeatMode: String, volume: Int, muted: Bool)?
    private static var pollsSinceSettings = 0

    /// Called after this app writes a setting, so the next poll reads it back.
    static func invalidateSettings() {
        cacheLock.lock(); cachedSettings = nil; cacheLock.unlock()
    }

    private static let coreQuery = joinHandler + """
    tell application id "com.apple.Music"
        set mqState to (player state as text)
        set mqID to "0"
        set mqPos to "0"
        try
            set mqID to ((database ID of current track) as text)
        end try
        try
            set mqPos to ((player position) as text)
        end try
    end tell
    return my joinList({mqState, mqID, mqPos})
    """

    private static let trackQuery = joinHandler + """
    tell application id "com.apple.Music"
        set mqID to "0"
        set mqName to ""
        set mqArtist to ""
        set mqAlbum to ""
        set mqDur to "0"
        try
            set mqTrack to current track
            set mqID to ((database ID of mqTrack) as text)
            set mqName to (name of mqTrack)
            set mqArtist to (artist of mqTrack)
            set mqAlbum to (album of mqTrack)
            set mqDur to ((duration of mqTrack) as text)
        end try
    end tell
    return my joinList({mqID, mqName, mqArtist, mqAlbum, mqDur})
    """

    private static let settingsQuery = joinHandler + """
    tell application id "com.apple.Music"
        set mqShuffle to ((shuffle enabled) as text)
        set mqRepeat to ((song repeat) as text)
        set mqVol to ((sound volume) as text)
        set mqMute to ((mute) as text)
    end tell
    return my joinList({mqShuffle, mqRepeat, mqVol, mqMute})
    """

    static func nowPlaying() throws -> NowPlaying {
        guard isRunning else { return NowPlaying() }
        let core = try ScriptRunner.shared.string(coreQuery).components(separatedBy: RS)
        guard core.count >= 3 else { return NowPlaying() }

        var np = NowPlaying()
        np.state = PlayerState(appleScript: core[0])
        let dbID = Int(core[1]) ?? 0
        np.position = number(core[2])

        cacheLock.lock()
        var track = cachedTrack
        var settings = cachedSettings
        pollsSinceSettings += 1
        let settingsDue = settings == nil || pollsSinceSettings >= 3
        cacheLock.unlock()

        if dbID == 0 {
            track = nil
        } else if track?.databaseID != dbID {
            let f = try ScriptRunner.shared.string(trackQuery).components(separatedBy: RS)
            // The track can change between the two queries; only keep details
            // that belong to the id this poll is reporting.
            if f.count >= 5, Int(f[0]) == dbID {
                track = MusicTrack(databaseID: dbID, name: f[1], artist: f[2],
                                   album: f[3], duration: number(f[4]))
            } else {
                track = MusicTrack(databaseID: dbID, name: "", artist: "", album: "", duration: 0)
            }
        }
        if settingsDue {
            let f = try ScriptRunner.shared.string(settingsQuery).components(separatedBy: RS)
            if f.count >= 4 {
                settings = (f[0] == "true", f[1], Int(Double(f[2]) ?? 100), f[3] == "true")
            }
        }

        cacheLock.lock()
        if let track, !track.name.isEmpty { cachedTrack = track } else if dbID == 0 { cachedTrack = nil }
        if settingsDue, let settings { cachedSettings = settings; pollsSinceSettings = 0 }
        cacheLock.unlock()

        np.track = track
        if let settings {
            np.shuffle = settings.shuffle
            np.repeatMode = settings.repeatMode
            np.volume = settings.volume
            np.muted = settings.muted
        }
        return np
    }

    /// Runs a script that writes artwork bytes to a file, in a separate
    /// `osascript` process that is killed if it overruns.
    ///
    /// Artwork is the one request Music has been seen to never answer: the
    /// app sat for days inside `raw data of artwork` on a cloud track, with
    /// AppleScript's own two-minute timeout never firing. In-process that
    /// blocked the shared script queue, and with it now-playing, playlists and
    /// everything else. A child process can simply be killed. The child's
    /// Apple Events are attributed to this app, so it needs no permission of
    /// its own.
    private static func isolatedArtwork(body: String, deadline: TimeInterval = 4) -> NSImage? {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("menuqueue-art-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let script = """
        set mqData to missing value
        tell application id "com.apple.Music"
            with timeout of 3 seconds
                \(body)
            end timeout
        end tell
        if mqData is missing value then return "none"
        set mqFile to open for access (POSIX file "\(file.path)") with write permission
        try
            write mqData to mqFile
        end try
        close access mqFile
        return "ok"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let until = Date().addingTimeInterval(deadline)
        while process.isRunning && Date() < until { usleep(20_000) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            return nil
        }
        guard let data = try? Data(contentsOf: file), data.count > 16 else { return nil }
        return NSImage(data: data)
    }

    /// Artwork for a specific library track. Resolved the same way playback is:
    /// cloud tracks only exist inside their own playlist, never in the library
    /// playlist, so the container has to come with the id.
    static func artwork(databaseID: Int, playlistID: String?) -> NSImage? {
        let pid = esc(playlistID ?? "")
        let container = playlistID == nil
            ? "library playlist 1"
            : "(first playlist whose persistent ID is \"\(pid)\")"
        return isolatedArtwork(body: """
            try
                    set mqMatches to (every track of \(container) whose database ID is \(databaseID))
                    if mqMatches is not {} then set mqData to raw data of artwork 1 of (item 1 of mqMatches)
                end try
            """)
    }

    static func artworkOfCurrentTrack() -> NSImage? {
        guard isRunning else { return nil }
        // Same isolation: this one runs inside the now-playing poll, so a hang
        // here used to stop the menu bar from ever updating again.
        return isolatedArtwork(body: """
            try
                    set mqData to raw data of artwork 1 of current track
                end try
            """)
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
        defer { invalidateSettings() }
        try tellMusic("set sound volume to \(max(0, min(100, v)))")
    }
    static func setShuffle(_ on: Bool) throws {
        defer { invalidateSettings() }
        try tellMusic("set shuffle enabled to \(on)")
    }
    /// mode: off | one | all
    static func setRepeat(_ mode: String) throws {
        defer { invalidateSettings() }
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
            -- `playlist`, not `user playlist`: a folder is neither, and asking
            -- for it as a user playlist throws rather than coming back empty.
            set mqPL to (first playlist whose persistent ID is "\(pid)")
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
