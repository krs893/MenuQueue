import Foundation

/// An in-memory snapshot of every user playlist's tracks, fetched in one
/// AppleScript round trip.
///
/// Why this exists instead of `search library playlist 1`:
///
/// With an iCloud / Apple Music library, playlist entries are `shared track`s
/// that do **not** live in `library playlist 1` — that container only holds
/// locally stored files. Measured on this machine: the library playlist has 93
/// tracks while the playlists hold 593, and searching the library for 20 sampled
/// playlist titles matched **0 of 20** by persistent ID. Music's own search verb
/// therefore returns nothing for most of the library.
///
/// Loading everything once and filtering in Swift is both correct and fast:
/// the whole fetch is a single Apple Event round trip per property per playlist
/// (measured 1.23 s for 593 tracks across 9 playlists), and every search after
/// that is instant.
///
/// Track identity stays `databaseID` + `sourcePlaylistID`, which is what
/// `MusicBridge.play(databaseID:playlistID:)` resolves against — verified to
/// resolve 15/15 sampled cloud tracks inside their own playlist, where a plain
/// library lookup resolves none.
final class LibraryIndex {

    static let shared = LibraryIndex()

    /// Separators chosen from the C0 control block: they cannot occur in track
    /// metadata, so a title containing a newline or a tab cannot shift columns.
    private static let RS = "\u{1E}"   // between items in a column
    private static let GS = "\u{1D}"   // between columns of one playlist
    private static let US = "\u{1F}"   // between playlists

    private let lock = NSLock()
    private var tracks: [MusicTrack] = []
    private var counts: [String: Int] = [:]
    private var loadedAt: Date?

    private static let maxAge: TimeInterval = 300

    var isLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        return loadedAt != nil
    }

    var trackCount: Int {
        lock.lock(); defer { lock.unlock() }
        return tracks.count
    }

    /// Track counts keyed by playlist persistent ID, free once the index is
    /// loaded — `count of tracks` per playlist costs an Apple Event each.
    func playlistCounts() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return counts
    }

    /// Whether the snapshot was taken within the last `seconds`.
    func isFresh(within seconds: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let loadedAt else { return false }
        return Date().timeIntervalSince(loadedAt) < seconds
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        loadedAt = nil
    }

    /// Must be called off the main thread — it may block for about a second
    /// on a cold index.
    func search(_ query: String, limit: Int = 80) throws -> [MusicTrack] {
        try loadIfNeeded()

        lock.lock()
        let snapshot = tracks
        lock.unlock()
        return Self.match(snapshot, query: query, limit: limit)
    }

    /// Pure so it can be tested without touching Music.
    ///
    /// Every whitespace-separated term has to appear somewhere in the title,
    /// artist or album, which makes "regal 1997" behave the way people expect.
    /// Title matches are listed first.
    static func match(_ tracks: [MusicTrack], query: String, limit: Int = 80) -> [MusicTrack] {
        let needles = fold(query)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !needles.isEmpty else { return [] }

        var titleHits: [MusicTrack] = []
        var otherHits: [MusicTrack] = []
        var seen = Set<String>()

        for track in tracks {
            let title = fold(track.name)
            let rest = fold(track.artist + " " + track.album)
            guard needles.allSatisfy({ title.contains($0) || rest.contains($0) }) else { continue }
            // The same song sitting in several playlists should appear once.
            // Cloud tracks get a distinct databaseID per playlist entry, so the
            // identity has to come from the metadata. Album is part of the key
            // so a single and an album cut stay separate — they are different
            // masters with different durations.
            guard seen.insert(identity(track)).inserted else { continue }
            if needles.allSatisfy({ title.contains($0) }) {
                titleHits.append(track)
            } else {
                otherHits.append(track)
            }
            if titleHits.count >= limit { break }
        }

        // Newest first, so a song added a moment ago is at the top rather than
        // wherever the playlists happened to put it. Relevance still wins: a
        // title match outranks an artist or album match.
        //
        // Most of an Apple Music library has no date at all — every track of a
        // subscription playlist reports `missing value` — so those all compare
        // equal. Swift's sort is not stable, which would reshuffle them on
        // every keystroke, so the original position breaks the tie and undated
        // tracks keep the order the playlists gave them, below the dated ones.
        func newestFirst(_ group: [(offset: Int, element: MusicTrack)]) -> [MusicTrack] {
            group.sorted {
                $0.element.addedAt == $1.element.addedAt
                    ? $0.offset < $1.offset
                    : $0.element.addedAt > $1.element.addedAt
            }.map(\.element)
        }
        let ordered = newestFirst(Array(titleHits.enumerated()))
                    + newestFirst(Array(otherHits.enumerated()))
        return Array(ordered.prefix(limit))
    }

    /// Loads the index ahead of the first search. Safe to call repeatedly;
    /// it is a no-op while the snapshot is fresh.
    func warm() {
        Task.detached(priority: .utility) { [weak self] in
            try? self?.loadIfNeeded()
        }
    }

    func reload() throws {
        invalidate()
        try loadIfNeeded()
    }

    private static func identity(_ t: MusicTrack) -> String {
        fold(t.name) + "\u{01}" + fold(t.artist) + "\u{01}" + fold(t.album)
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
    }

    private func loadIfNeeded() throws {
        lock.lock()
        let fresh = loadedAt.map { Date().timeIntervalSince($0) < Self.maxAge } ?? false
        lock.unlock()
        guard !fresh else { return }

        let raw = try ScriptRunner.shared.string(Self.source)
        let (parsed, parsedCounts) = Self.parse(raw)

        lock.lock()
        tracks = parsed
        counts = parsedCounts
        loadedAt = Date()
        lock.unlock()
    }

    // MARK: - AppleScript

    /// `joinSafe` coerces each element inside a `try`, because a cloud track can
    /// report `missing value` for a property and coercing the whole list would
    /// then abort the call. The loop runs on an already-fetched local list, so
    /// it costs no Apple Events.
    private static let source = """
    -- Dates cannot be coerced to text in a locale-independent way, so subtract
    -- a constructed epoch and keep the seconds. Only the relative order is used.
    on joinDates(lst, mqEpoch)
        set mqAcc to {}
        repeat with v in lst
            try
                set end of mqAcc to ((((contents of v) - mqEpoch) as integer) as text)
            on error
                set end of mqAcc to "0"
            end try
        end repeat
        set od to AppleScript's text item delimiters
        set AppleScript's text item delimiters to (character id 30)
        set s to mqAcc as text
        set AppleScript's text item delimiters to od
        return s
    end joinDates

    on joinSafe(lst)
        set mqAcc to {}
        repeat with v in lst
            try
                set end of mqAcc to ((contents of v) as text)
            on error
                set end of mqAcc to ""
            end try
        end repeat
        set od to AppleScript's text item delimiters
        set AppleScript's text item delimiters to (character id 30)
        set s to mqAcc as text
        set AppleScript's text item delimiters to od
        return s
    end joinSafe

    set mqGS to (character id 29)
    set mqChunks to {}
    set mqEpoch to (current date)
    set year of mqEpoch to 1970
    set month of mqEpoch to January
    set day of mqEpoch to 1
    set time of mqEpoch to 0

    tell application id "com.apple.Music"
        set mqPLIDs to (persistent ID of every user playlist)
        set mqPLNames to (name of every user playlist)
        set mqPLClasses to (class of every user playlist)
        repeat with mqI from 1 to (count of mqPLIDs)
            set mqCls to ((item mqI of mqPLClasses) as text)
            if mqCls is not "folder playlist" then
                set mqPID to (item mqI of mqPLIDs)
                try
                    set mqPL to (first user playlist whose persistent ID is mqPID)
                    -- Bulk property access throws on an empty playlist: `every
                    -- track` yields {} but `database ID of every track` fails
                    -- outright. Empty playlists are ordinary (a smart playlist
                    -- matching nothing), so answer with empty columns.
                    if (count of tracks of mqPL) is 0 then
                        set end of mqChunks to (mqPID & mqGS & "" & mqGS & "" & mqGS & "" & mqGS & "" & mqGS & "" & mqGS & "")
                    else
                    set mqA to my joinSafe(database ID of every track of mqPL)
                    set mqB to my joinSafe(name of every track of mqPL)
                    set mqC to my joinSafe(artist of every track of mqPL)
                    set mqD to my joinSafe(album of every track of mqPL)
                    set mqE to my joinSafe(duration of every track of mqPL)
                    -- Streaming tracks report `date added` as missing value —
                    -- every entry of a subscription playlist does — and asking
                    -- for the column can fail outright. Never let that cost us
                    -- the playlist itself.
                    set mqF to ""
                    try
                        set mqF to my joinDates(date added of every track of mqPL, mqEpoch)
                    end try
                    set end of mqChunks to (mqPID & mqGS & mqA & mqGS & mqB & mqGS & mqC & mqGS & mqD & mqGS & mqE & mqGS & mqF)
                    end if
                end try
            end if
        end repeat
    end tell

    set od to AppleScript's text item delimiters
    set AppleScript's text item delimiters to (character id 31)
    set mqOut to mqChunks as text
    set AppleScript's text item delimiters to od
    return mqOut
    """

    static func parse(_ raw: String) -> ([MusicTrack], [String: Int]) {
        var tracks: [MusicTrack] = []
        var counts: [String: Int] = [:]
        guard !raw.isEmpty else { return ([], [:]) }

        for chunk in raw.components(separatedBy: US) {
            let columns = chunk.components(separatedBy: GS)
            guard columns.count >= 6 else { continue }
            let playlistID = columns[0]
            guard !playlistID.isEmpty else { continue }

            let ids      = split(columns[1])
            let names    = split(columns[2])
            let artists  = split(columns[3])
            let albums   = split(columns[4])
            let durations = split(columns[5])
            let added = columns.count > 6 ? split(columns[6]) : []

            let n = ids.count
            counts[playlistID] = n
            guard n > 0, names.count == n else { continue }

            for i in 0..<n {
                guard let dbID = Int(ids[i]) else { continue }
                tracks.append(MusicTrack(
                    databaseID: dbID,
                    name: names[i],
                    artist: i < artists.count ? artists[i] : "",
                    album: i < albums.count ? albums[i] : "",
                    duration: i < durations.count ? sanitiseDuration(durations[i]) : 0,
                    sourcePlaylistID: playlistID,
                    addedAt: i < added.count ? (Double(added[i]) ?? 0) : 0
                ))
            }
        }
        return (tracks, counts)
    }

    /// `Double("nan")`, `"inf"` and negatives all parse happily, and a
    /// non-finite duration reaches SwiftUI's progress slider as the upper bound
    /// of its range, which is not a value a Slider can take.
    private static func sanitiseDuration(_ raw: String) -> Double {
        guard let value = Double(raw), value.isFinite, value > 0 else { return 0 }
        return value
    }

    /// An empty column means zero items, not one empty item.
    private static func split(_ column: String) -> [String] {
        column.isEmpty ? [] : column.components(separatedBy: RS)
    }
}
