import Foundation
import AppKit

@main
struct RegressionTests {
    @MainActor static func main() async throws {
        let shuffleLibrary = LibraryModel()
        let root = PlaylistInfo(id: "root", name: "Folder", count: 0, isFolder: true)
        let shuffleNested = PlaylistInfo(id: "nested", name: "Nested", count: 0, parentID: "root", isFolder: true)
        let a = PlaylistInfo(id: "a", name: "A", count: 2, parentID: "root")
        let b = PlaylistInfo(id: "b", name: "B", count: 2, parentID: "nested")
        let outside = PlaylistInfo(id: "outside", name: "Outside", count: 1)
        shuffleLibrary.playlists = [root, shuffleNested, a, b, outside]
        assert(Set(shuffleLibrary.playbackPlaylists(in: root).map(\.id)) == ["a", "b"])
        assert(shuffleLibrary.playbackPlaylists(in: a).map(\.id) == ["a"])
        func song(_ id: Int) -> MusicTrack {
            MusicTrack(databaseID: id, name: "Song", artist: "", album: "", duration: 100)
        }
        MusicBridge.stubTracks = ["a": [song(1), song(2)], "b": [song(2), song(3)], "outside": [song(4)]]
        let shuffleURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shuffleURL) }
        let shuffleStore = QueueStore(fileURL: shuffleURL)
        let shufflePlayer = PlayerController(store: shuffleStore, startPolling: false)
        await shuffleLibrary.shufflePlay(root, player: shufflePlayer)
        assert(shuffleStore.shuffleActive && shufflePlayer.owns)
        assert(shuffleStore.items.count == 3)
        assert(Set(shuffleStore.items.map { $0.track.databaseID }) == [1, 2, 3])
        assert(shuffleStore.items.allSatisfy { ["a", "b"].contains($0.track.sourcePlaylistID ?? "") })
        assert(shuffleStore.currentID == shuffleStore.items.first?.id)
        let readsBeforeDirectPlay = MusicBridge.trackReadCount
        await shuffleLibrary.shufflePlay(a, player: shufflePlayer)
        assert(MusicBridge.shuffledPlaylists.last == "a" && !shufflePlayer.owns)
        assert(MusicBridge.trackReadCount == readsBeforeDirectPlay,
               "Direct playlist shuffle must not enumerate tracks")
        let beforeEmpty = shuffleStore.items
        MusicBridge.stubTracks = [:]
        await shuffleLibrary.shufflePlay(a, player: shufflePlayer)
        assert(shuffleStore.items == beforeEmpty && shuffleLibrary.playlistError != nil)
        await shufflePlayer.clearQueue()
        MusicBridge.plays = []
        MusicBridge.repeatWrites = []
        MusicBridge.snapshot = NowPlaying()
        print("PASS: scoped shuffle, nested folders, duplicate songs, source context, and empty preservation")

        // Most queue tests exercise repeat borrowing, which is opt-in now.
        UserDefaults.standard.set(true, forKey: "gaplessTakeover")
        assert(QueueTextParser.firstText(["", "  ", "Song description"]) == "Song description")
        assert(QueueTextParser.firstText(["\u{FFFC} AutoPlay"]) == "AutoPlay")
        for heading in ["再生を続ける", "Continue Playing", "次に再生", "Playing Next", "\u{FFFC} AutoPlay", "Playlist name"] {
            let rows: [QueueTextParser.Row] = [
                .init(texts: ["履歴"], hasTrackMenu: false),
                .init(texts: ["Past song"], hasTrackMenu: true),
                .init(texts: [heading], hasTrackMenu: false),
                .init(texts: ["Upcoming song", "Artist"], hasTrackMenu: true),
                .init(texts: ["History"], hasTrackMenu: true)
            ]
            let parsed = QueueTextParser.upcoming(rows)
            assert(parsed.map { $0.title } == ["Upcoming song", "History"], heading)
            assert(parsed.first?.subtitle == "Artist")
        }
        assert(QueueTextParser.upcoming([.init(texts: ["History"], hasTrackMenu: false), .init(texts: ["Old song"], hasTrackMenu: true)]).isEmpty)
        print("PASS: native queue section boundaries, history exclusion, and empty AX value fallback")

        // LibraryIndex: the column-per-property payload must survive metadata
        // that contains the characters a naive delimiter would collide with.
        let RS = "\u{1E}", GS = "\u{1D}", US = "\u{1F}"
        let chunkA = ["PLA",
                      ["11", "12"].joined(separator: RS),
                      ["Tab\there", "New\nline"].joined(separator: RS),
                      ["Artist A", "Artist B"].joined(separator: RS),
                      ["Album A", "Album B"].joined(separator: RS),
                      ["215.2", "216.3"].joined(separator: RS)].joined(separator: GS)
        // An empty playlist sends empty columns, which must read as zero
        // tracks rather than one blank one.
        let chunkB = ["PLB", "", "", "", "", ""].joined(separator: GS)
        let (parsed, counts) = LibraryIndex.parse([chunkA, chunkB].joined(separator: US))
        assert(parsed.count == 2, "expected 2 tracks, got \(parsed.count)")
        assert(parsed[0].name == "Tab\there" && parsed[1].name == "New\nline")
        assert(parsed[0].sourcePlaylistID == "PLA")
        assert(parsed[0].duration == 215.2)
        assert(counts["PLA"] == 2 && counts["PLB"] == 0)

        // A cloud track carrying `missing value` arrives as an empty field and
        // must not drop the row or shift the columns after it.
        let ragged = ["PLC", ["21", "22"].joined(separator: RS),
                      ["Only", "Both"].joined(separator: RS),
                      "", "", ""].joined(separator: GS)
        let (raggedTracks, _) = LibraryIndex.parse(ragged)
        assert(raggedTracks.count == 2 && raggedTracks[1].artist.isEmpty && raggedTracks[1].duration == 0)

        assert(LibraryIndex.parse("").0.isEmpty)
        print("PASS: library index payload parsing, empty playlists and missing properties")

        // Matching: folding, multi-term AND, title-first ordering, and the
        // dedup rule that keeps a single and an album cut apart.
        let single = MusicTrack(databaseID: 854, name: "ハイキ", artist: "リーガルリリー",
                                album: "ハイキ - Single", duration: 215.2, sourcePlaylistID: "PLA")
        let albumCut = MusicTrack(databaseID: 821, name: "ハイキ", artist: "リーガルリリー",
                                  album: "kirin", duration: 216.3, sourcePlaylistID: "PLB")
        let dupe = MusicTrack(databaseID: 999, name: "ハイキ", artist: "リーガルリリー",
                              album: "ハイキ - Single", duration: 215.2, sourcePlaylistID: "PLC")
        let byArtist = MusicTrack(databaseID: 700, name: "Memories", artist: "ハイキ Band",
                                  album: "X", duration: 60, sourcePlaylistID: "PLA")
        let catalogue = [byArtist, single, albumCut, dupe]

        let hits = LibraryIndex.match(catalogue, query: "ハイキ")
        assert(hits.count == 3, "same song in two playlists collapses, different masters do not: \(hits.count)")
        assert(hits.map(\.databaseID) == [854, 821, 700], "title matches come before artist matches")
        assert(LibraryIndex.match(catalogue, query: "MEMORIES").count == 1, "case folding")
        assert(LibraryIndex.match(catalogue, query: "ﾊｲｷ").count == 3, "half-width kana folding")
        assert(LibraryIndex.match(catalogue, query: "ハイキ kirin").map(\.databaseID) == [821],
               "every term must match")
        assert(LibraryIndex.match(catalogue, query: "   ").isEmpty)
        assert(LibraryIndex.match(catalogue, query: "ハイキ", limit: 1).count == 1)
        print("PASS: library search folding, multi-term matching and release-aware dedup")

        // The index loads once and is reused: a per-keystroke search must not
        // pay for another round trip.
        ScriptRunner.canned = chunkA
        ScriptRunner.calls = 0
        let index = LibraryIndex.shared
        try index.reload()
        assert(index.trackCount == 2)
        _ = try index.search("Tab")
        _ = try index.search("New")
        assert(ScriptRunner.calls == 1, "index reloaded per search: \(ScriptRunner.calls)")
        assert(index.playlistCounts()["PLA"] == 2)
        print("PASS: library index caches one load across searches")

        // A song added to the library after the snapshot was taken has to be
        // findable: the refresh action drops the snapshot rather than waiting
        // for it to age out.
        let RS3 = "\u{1E}", GS3 = "\u{1D}"
        func chunk(_ ids: [String]) -> String {
            [ "PLA",
              ids.joined(separator: RS3),
              ids.map { "song \($0)" }.joined(separator: RS3),
              ids.map { _ in "artist" }.joined(separator: RS3),
              ids.map { _ in "album" }.joined(separator: RS3),
              ids.map { _ in "100" }.joined(separator: RS3) ].joined(separator: GS3)
        }
        ScriptRunner.canned = chunk(["11", "12"])
        try index.reload()
        var found = try index.search("song").count
        assert(found == 2)
        // The user adds a track in Music.
        ScriptRunner.canned = chunk(["11", "12", "13"])
        found = try index.search("song").count
        assert(found == 2, "the cached snapshot is reused")
        index.invalidate()
        found = try index.search("song").count
        assert(found == 3, "refresh must pick up the new track")
        assert(index.isFresh(within: 60) && !index.isFresh(within: 0))
        print("PASS: refreshing the library picks up newly added songs")

        // Recently added songs come first, and the tracks Music gives no date
        // for — every entry of a subscription playlist — must keep a stable
        // order instead of being reshuffled by an unstable sort on each keystroke.
        func chunkDated(_ rows: [(String, String, String)]) -> String {
            [ "PLD",
              rows.map { $0.0 }.joined(separator: RS3),
              rows.map { $0.1 }.joined(separator: RS3),
              rows.map { _ in "artist" }.joined(separator: RS3),
              rows.map { _ in "album" }.joined(separator: RS3),
              rows.map { _ in "100" }.joined(separator: RS3),
              rows.map { $0.2 }.joined(separator: RS3) ].joined(separator: GS3)
        }
        ScriptRunner.canned = chunkDated([
            ("1", "song old",   "1000"),
            ("2", "song undated a", "0"),
            ("3", "song new",   "9000"),
            ("4", "song undated b", "0"),
        ])
        index.invalidate()
        let ranked = try index.search("song")
        assert(ranked.map(\MusicTrack.name) == ["song new", "song old", "song undated a", "song undated b"],
               "newest first, undated last in load order: \(ranked.map(\MusicTrack.name))")
        for _ in 0..<20 {
            let again = try index.search("song").map(\MusicTrack.name)
            assert(again == ranked.map(\MusicTrack.name),
                   "the order must not change between identical searches")
        }
        // A playlist whose date column is missing entirely still yields tracks.
        ScriptRunner.canned = ["PLE", "7", "song lone", "a", "b", "100"].joined(separator: GS3)
        index.invalidate()
        let lone = try index.search("lone").count
        assert(lone == 1, "a missing date column must not drop the playlist")
        print("PASS: recently added first, undated tracks keep a stable order")

        // The menu bar ticker: a short title must sit still, a long one has to
        // loop cleanly, and the item width has to stay constant either way.
        assert(!Marquee.scrolls("短い", width: 14))
        assert(Marquee.window("短い", width: 14, step: 99) == "短い", "a short title never moves")
        assert(Marquee.parked("短い", width: 14) == "短い")

        let long = "とても長い曲名がここにあって収まらない"
        assert(Marquee.scrolls(long, width: 8))
        let first = Marquee.window(long, width: 8, step: 0)
        assert(first.count == 8 && first == String(long.prefix(8)))
        // Every step keeps the same width, including across the wrap.
        for step in 0..<200 {
            assert(Marquee.window(long, width: 8, step: step).count == 8,
                   "width drifted at step \(step)")
        }
        // One full loop is text + gap, and it returns to where it started.
        let period = long.count + Marquee.gap.count
        assert(Marquee.window(long, width: 8, step: period) == first, "the loop must close")
        assert(Marquee.window(long, width: 8, step: -1) == Marquee.window(long, width: 8, step: period - 1),
               "a negative step must not index out of the loop")
        // Parked titles show the head, not the middle of a scroll.
        assert(Marquee.parked(long, width: 8) == String(long.prefix(7)) + "…")
        assert(Marquee.window("", width: 8, step: 3).isEmpty)
        assert(Marquee.window(long, width: 0, step: 3).isEmpty)
        assert(!Marquee.scrolls(long, width: 0))
        print("PASS: the menu bar ticker keeps a constant width and loops cleanly")
        let tickerView = TickerView(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        tickerView.show("MMMMMMMMMMMMMMMM", font: NSFont.systemFont(ofSize: 12))
        let tickerImage = tickerView.layer!.sublayers!.first!.contents as! CGImage
        let tickerBitmap = NSBitmapImageRep(cgImage: tickerImage)
        var lastInkX = 0
        for x in 0..<tickerBitmap.pixelsWide {
            for y in 0..<tickerBitmap.pixelsHigh {
                if (tickerBitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                    lastInkX = x
                    break
                }
            }
        }
        assert(Double(lastInkX) > Double(tickerBitmap.pixelsWide) * 0.9,
               "Scrolling title must fill its point-sized strip without Retina shrinkage")
        tickerView.stop()
        print("PASS: scrolling title bitmap preserves fixed font size at display scale")

        // Album art is cached per album, not per track: a playlist of 271 songs
        // spanned 84 albums here, so keying by track would fetch three times
        // over for no benefit.
        let a1 = MusicTrack(databaseID: 1, name: "one", artist: "Band", album: "Record", duration: 1)
        let a2 = MusicTrack(databaseID: 2, name: "two", artist: "Band", album: "Record", duration: 1)
        let a3 = MusicTrack(databaseID: 3, name: "three", artist: "Band", album: "Other", duration: 1)
        assert(ArtworkStore.key(a1) == ArtworkStore.key(a2), "same album shares one fetch")
        assert(ArtworkStore.key(a1) != ArtworkStore.key(a3))
        // Case and padding in the metadata must not split the cache.
        let a4 = MusicTrack(databaseID: 4, name: "four", artist: "BAND", album: " Record ", duration: 1)
        assert(ArtworkStore.key(a1) == ArtworkStore.key(a4))
        // A track with no album falls back to its own id rather than sharing a
        // blank key with every other album-less track.
        let b1 = MusicTrack(databaseID: 5, name: "x", artist: "Band", album: "", duration: 1)
        let b2 = MusicTrack(databaseID: 6, name: "y", artist: "Band", album: "   ", duration: 1)
        assert(ArtworkStore.key(b1) != ArtworkStore.key(b2))

        // Music hands back full size covers; what gets cached has to be small.
        let big = NSImage(size: NSSize(width: 1200, height: 900))
        big.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 1200, height: 900).fill()
        big.unlockFocus()
        let thumb = ArtworkStore.downscale(big, to: ArtworkStore.side)
        assert(thumb != nil)
        assert(thumb!.size == NSSize(width: ArtworkStore.side, height: ArtworkStore.side),
               "a non-square cover must come out square, not stretched")
        print("PASS: album art is cached per album and stored as a thumbnail")

        // Playlist folders: Music nests playlists, and a flat list loses that.
        let folderA = PlaylistInfo(id: "F1", name: "Rock in Japan", count: 0, parentID: nil, isFolder: true)
        let folderB = PlaylistInfo(id: "F2", name: "月の曲", count: 0, parentID: nil, isFolder: true)
        let nested  = PlaylistInfo(id: "F3", name: "nested", count: 0, parentID: "F1", isFolder: true)
        let inA     = PlaylistInfo(id: "P1", name: "Chevon", count: 9, parentID: "F1")
        let inNested = PlaylistInfo(id: "P2", name: "deep", count: 3, parentID: "F3")
        let top     = PlaylistInfo(id: "P3", name: "SUKI", count: 271, parentID: nil)
        let model = LibraryModel()
        model.playlists = [inA, folderA, top, folderB, nested, inNested]

        // Folders come first, and only what belongs at this level is listed.
        assert(model.visibleEntries.map(\PlaylistInfo.id) == ["F1", "F2", "P3"],
               "top level: \(model.visibleEntries.map(\PlaylistInfo.name))")
        assert(model.childCount(of: folderA) == 2)
        assert(!model.canGoBack)

        model.enter(folderA)
        assert(model.visibleEntries.map(\PlaylistInfo.id) == ["F3", "P1"])
        assert(model.currentFolder?.id == "F1" && model.canGoBack)
        model.enter(nested)
        assert(model.visibleEntries.map(\PlaylistInfo.id) == ["P2"], "folders nest arbitrarily deep")
        // Entering a playlist is not entering a folder.
        model.enter(inNested)
        assert(model.currentFolder?.id == "F3")

        assert(model.goBack() && model.currentFolder?.id == "F1")
        assert(model.goBack() && model.currentFolder == nil)
        assert(!model.goBack(), "nowhere left to go")

        // A folder that disappears from Music must not strand the panel inside it.
        model.enter(folderA)
        model.enter(nested)
        model.playlists = [top]
        model.reconcileFolderPath()
        assert(model.currentFolder == nil && model.visibleEntries.map(\PlaylistInfo.id) == ["P3"])
        print("PASS: playlist folders browse and survive disappearing")

        // Hold the image service open: polling and Next must still complete,
        // and its stale image must not overwrite the next song's image.
        let artURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: artURL) }
        let artPlayer = PlayerController(store: QueueStore(fileURL: artURL), startPolling: false)
        let oldImage = NSImage(size: NSSize(width: 10, height: 10))
        let newImage = NSImage(size: NSSize(width: 20, height: 20))
        let artGate = DispatchSemaphore(value: 0)
        while MusicBridge.artworkStarted.consume() {}
        MusicBridge.artworkGate = artGate
        MusicBridge.currentArtwork = oldImage
        let artworkFetchesBefore = MusicBridge.currentArtworkFetches
        MusicBridge.snapshot = NowPlaying(state: .playing, track: song(888))
        let pollCompleted = TestSignal()
        let imageBlockedPoll = Task { await artPlayer.tick(); pollCompleted.signal() }
        let imageStartDeadline = Date().addingTimeInterval(3)
        while !MusicBridge.artworkStarted.consume() {
            assert(Date() < imageStartDeadline)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let pollDeadline = Date().addingTimeInterval(0.5)
        var completedWhileBlocked = false
        repeat {
            completedWhileBlocked = pollCompleted.consume()
            if completedWhileBlocked { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        } while Date() < pollDeadline
        assert(completedWhileBlocked, "Polling waited for the blocked artwork request")
        assert(artPlayer.now.track?.databaseID == 888 && artPlayer.artwork == nil)
        MusicBridge.currentArtwork = newImage
        MusicBridge.artworkGate = nil
        MusicBridge.snapshot.track = song(889)
        await artPlayer.tick()
        MusicBridge.snapshot.track = song(890)
        await artPlayer.tick()
        let nextCount = MusicBridge.nativeNextCount
        artPlayer.next()
        artPlayer.next()
        let nextDeadline = Date().addingTimeInterval(0.5)
        while artPlayer.pendingSkipCount > 0 && Date() < nextDeadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        assert(MusicBridge.nativeNextCount == nextCount + 2 && artPlayer.pendingSkipCount == 0,
               "Next must complete while the previous artwork fetch is blocked")
        assert(artPlayer.now.track?.databaseID == 890 && artPlayer.artwork == nil)
        artGate.signal()
        await imageBlockedPoll.value
        let imageFinishDeadline = Date().addingTimeInterval(3)
        while artPlayer.artwork !== newImage {
            assert(Date() < imageFinishDeadline, "Latest artwork did not arrive")
            assert(artPlayer.artwork !== oldImage, "Stale artwork overwrote the current track")
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        assert(MusicBridge.currentArtworkFetches == artworkFetchesBefore + 2,
               "Cancelled queued images must be skipped before talking to Music")
        MusicBridge.snapshot.track = song(891)
        while MusicBridge.readStarted.consume() {}
        MusicBridge.readDelay = 0.15
        let shutdownPoll = Task { await artPlayer.tick() }
        let shutdownReadDeadline = Date().addingTimeInterval(3)
        while !MusicBridge.readStarted.consume() {
            assert(Date() < shutdownReadDeadline)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        artPlayer.shutdown()
        await shutdownPoll.value
        MusicBridge.readDelay = 0
        await artPlayer.tick()
        assert(artPlayer.now.track?.databaseID == 890, "Shutdown must disable later notification reads")
        MusicBridge.currentArtwork = nil
        MusicBridge.nativeNextCount = nextCount
        print("PASS: blocked artwork cannot delay polling/Next or overwrite the next track's art")

        // Choosing the second song of a playlist plays it and then carries on
        // through the rest: Music drops the playlist context when a single
        // track is started from a script, so the app has to do the carrying.
        MusicBridge.isRunning = true
        MusicBridge.snapshot = NowPlaying()
        MusicBridge.snapshot.repeatMode = "all"
        MusicBridge.plays = []
        MusicBridge.repeatWrites = []
        MusicBridge.missing = false
        UserDefaults.standard.removeObject(forKey: "borrowedRepeatMode")
        // The shipped default: the user's repeat mode is left alone.
        UserDefaults.standard.set(false, forKey: "gaplessTakeover")
        let listDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: listDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: listDir) }
        let listStore = QueueStore(fileURL: listDir.appendingPathComponent("list.json"))
        let lister = PlayerController(store: listStore, startPolling: false)
        let album = (1...5).map { MusicTrack(databaseID: 100 + $0, name: "s\($0)", artist: "a", album: "b", duration: 100) }
        await lister.playFromPlaylist(album, startAt: 1)
        assert(MusicBridge.plays == [102], "the chosen track plays first: \(MusicBridge.plays)")
        assert(listStore.items.count == 5 && listStore.currentIndex == 1)
        assert(MusicBridge.repeatWrites.isEmpty,
               "playing through a playlist must not touch the user's repeat mode: \(MusicBridge.repeatWrites)")
        assert(UserDefaults.standard.string(forKey: "borrowedRepeatMode") == nil)
        await lister.advance(automatically: true)
        assert(MusicBridge.plays == [102, 103], "the next song follows: \(MusicBridge.plays)")
        // Out-of-range picks are ignored rather than crashing.
        await lister.playFromPlaylist(album, startAt: 9)
        await lister.playFromPlaylist([], startAt: 0)
        assert(MusicBridge.plays == [102, 103])
        await lister.clearQueue()
        assert(MusicBridge.repeatWrites.isEmpty, "nothing to hand back, nothing was taken")

        // The bug behind "the song I picked got skipped": right after a track
        // starts, Music can report the new track's id with the old track's
        // near-the-end position. That must not be taken as "this one is ending".
        MusicBridge.plays = []
        await lister.playFromPlaylist(album, startAt: 0)
        MusicBridge.snapshot.state = .playing
        MusicBridge.snapshot.position = 100 - PlayerController.handoffLead + 0.05
        await lister.tick()
        await lister.tick()
        assert(MusicBridge.plays == [101],
               "a stale end-of-song position straight after starting must not skip: \(MusicBridge.plays)")

        // Once the track is seen playing and moving forward, reaching the end
        // does hand over.
        MusicBridge.snapshot.position = 10
        await lister.tick()
        MusicBridge.snapshot.position = 11
        await lister.tick()
        MusicBridge.snapshot.position = 100 - PlayerController.handoffLead + 0.05
        await lister.tick()
        assert(MusicBridge.plays == [101, 102],
               "within the hand-off window the next track starts: \(MusicBridge.plays)")

        // The hand-off is timed locally rather than caught by polling fast: a
        // poll a second before the end schedules it, and it fires on its own.
        func playUntil(_ remaining: Double) async {
            MusicBridge.snapshot.state = .playing
            MusicBridge.snapshot.position = 10; await lister.tick()
            MusicBridge.snapshot.position = 11; await lister.tick()
            MusicBridge.snapshot.position = 100 - remaining; await lister.tick()
        }
        await playUntil(PlayerController.handoffLead + 0.3)
        assert(MusicBridge.plays == [101, 102], "nothing yet: still 0.3 s before the hand-off")
        try await Task.sleep(nanoseconds: 600_000_000)
        assert(MusicBridge.plays == [101, 102, 103],
               "the scheduled hand-off fires without another poll: \(MusicBridge.plays)")

        // Pausing stops the clock, so it must also call off the hand-off.
        await playUntil(PlayerController.handoffLead + 0.3)
        MusicBridge.snapshot.state = .paused
        await lister.tick()
        try await Task.sleep(nanoseconds: 600_000_000)
        assert(MusicBridge.plays == [101, 102, 103], "a paused track must not be handed over: \(MusicBridge.plays)")
        await lister.clearQueue()
        UserDefaults.standard.removeObject(forKey: "borrowedRepeatMode")
        // Back to the setting the remaining tests are written against. Not a
        // `defer`: that would only run at the end of this whole function.
        UserDefaults.standard.set(true, forKey: "gaplessTakeover")
        print("PASS: picking a track plays on through the rest of its playlist")

        MusicBridge.plays = []
        await lister.playFromPlaylist(album, startAt: 2)
        assert(lister.owns && MusicBridge.plays == [103], "Selection plays directly without a working playlist")
        assert(lister.store.items.map { $0.track.databaseID } == album.map(\.databaseID))
        await lister.clearQueue()
        print("PASS: selected tracks play without mutating the Music library")

        // A rejected next-track command must not consume the current song or
        // move the persisted pointer ahead of Music.
        UserDefaults.standard.set(false, forKey: "gaplessTakeover")
        listStore.consumeOnPlay = true
        MusicBridge.snapshot.repeatMode = "off"
        await lister.playFromPlaylist(album, startAt: 0)
        assert(!listStore.consumeOnPlay, "Playlist playback retains songs for Previous and looping")
        listStore.consumeOnPlay = true // Exercise generic queue consumption separately.
        let itemsBeforeRejectedPlay = listStore.items
        let idBeforeRejectedPlay = listStore.currentID
        MusicBridge.missing = true
        await lister.advance()
        assert(listStore.currentID == idBeforeRejectedPlay && listStore.items == itemsBeforeRejectedPlay)
        assert(QueueStore(fileURL: listDir.appendingPathComponent("list.json")).currentID == idBeforeRejectedPlay)
        MusicBridge.missing = false
        await lister.advance()
        assert(listStore.items.first?.track.databaseID == 102 && listStore.currentID == listStore.items.first?.id)
        await lister.clearQueue()
        listStore.consumeOnPlay = false

        // Matching IDs alone do not establish that audio started.
        var stalledClock = Date()
        lister.clock = { stalledClock }
        await lister.playFromPlaylist(album, startAt: 0)
        MusicBridge.snapshot.position = 0
        await lister.tick()
        stalledClock = stalledClock.addingTimeInterval(9)
        await lister.tick()
        assert(!lister.owns && lister.lastError != nil,
               "A track stuck at zero must fail visibly instead of waiting forever")
        await lister.clearQueue()
        lister.clock = { Date() }
        UserDefaults.standard.set(true, forKey: "gaplessTakeover")
        print("PASS: failed next play preserves the queue; zero-position buffering has a deadline")

        // The Next button must recover a managed single-track queue after
        // Music or MenuQueue was reopened, without taking over native lists.
        let skipURL = listDir.appendingPathComponent("next-recovery.json")
        let skipTracks = [
            MusicTrack(databaseID: 1334, name: "キッズリターン!", artist: "", album: "", duration: 100, sourcePlaylistID: "source-list"),
            MusicTrack(databaseID: 2872, name: "あかねさす頃", artist: "", album: "", duration: 100, sourcePlaylistID: "source-list")
        ]
        let nativeSkipsBeforeRecoveryTests = MusicBridge.nativeNextCount
        func waitForSkip(_ control: PlayerController) async throws {
            let deadline = Date().addingTimeInterval(3)
            while control.pendingSkipCount > 0 && Date() < deadline {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            assert(control.pendingSkipCount == 0, "Next did not finish")
        }
        func savedFirstTrack() -> QueueStore {
            let saved = QueueStore(fileURL: skipURL)
            saved.replaceAll(with: skipTracks)
            _ = saved.select(saved.items[0].id)
            saved.setManagedPlayback(true)
            MusicBridge.snapshot = NowPlaying(state: .playing, track: skipTracks[0])
            return saved
        }
        let initialSkipStore = savedFirstTrack()
        let musicRestartPlayer = PlayerController(store: initialSkipStore, startPolling: false)
        await musicRestartPlayer.play(item: initialSkipStore.items[0])
        MusicBridge.isRunning = false
        await musicRestartPlayer.tick()
        MusicBridge.isRunning = true
        MusicBridge.snapshot = NowPlaying(state: .paused, track: skipTracks[0])
        let playsBeforeRecoveredNext = MusicBridge.plays.count
        musicRestartPlayer.next()
        try await waitForSkip(musicRestartPlayer)
        assert(MusicBridge.plays.dropFirst(playsBeforeRecoveredNext) == [2872])
        assert(MusicBridge.nativeNextCount == nativeSkipsBeforeRecoveryTests)
        await musicRestartPlayer.clearQueue()

        _ = savedFirstTrack()
        let reloadedSkipStore = QueueStore(fileURL: skipURL)
        assert(reloadedSkipStore.managedPlaybackActive == true)
        let reopenedPlayer = PlayerController(store: reloadedSkipStore, startPolling: false)
        MusicBridge.nativePlaylistContext = "source-list"
        let playsBeforeReopenedNext = MusicBridge.plays.count
        reopenedPlayer.next()
        try await waitForSkip(reopenedPlayer)
        assert(MusicBridge.plays.dropFirst(playsBeforeReopenedNext) == [2872])
        await reopenedPlayer.clearQueue()
        MusicBridge.nativePlaylistContext = ""

        let stoppedStore = savedFirstTrack()
        let stoppedQueuePlayer = PlayerController(store: stoppedStore, startPolling: false)
        MusicBridge.snapshot = NowPlaying()
        stoppedQueuePlayer.next()
        try await waitForSkip(stoppedQueuePlayer)
        assert(MusicBridge.plays.last == 2872 && stoppedStore.currentIndex == 1)
        await stoppedQueuePlayer.clearQueue()

        // Read failures preserve the session for another click, never falling
        // through to Music's ineffective native Next for a single track.
        for failContext in [false, true] {
            _ = savedFirstTrack()
            let retryStore = QueueStore(fileURL: skipURL)
            let retryPlayer = PlayerController(store: retryStore, startPolling: false)
            MusicBridge.failRead = !failContext
            MusicBridge.failPlaylistContextRead = failContext
            let playsBeforeReadFailure = MusicBridge.plays.count
            let nativeBeforeReadFailure = MusicBridge.nativeNextCount
            retryPlayer.next()
            try await waitForSkip(retryPlayer)
            assert(retryPlayer.lastError != nil && retryStore.currentIndex == 0)
            assert(retryStore.managedPlaybackActive == true)
            assert(MusicBridge.plays.count == playsBeforeReadFailure && MusicBridge.nativeNextCount == nativeBeforeReadFailure)
            MusicBridge.failRead = false
            MusicBridge.failPlaylistContextRead = false
            retryPlayer.next()
            try await waitForSkip(retryPlayer)
            assert(MusicBridge.plays.last == 2872 && retryStore.currentIndex == 1)
            await retryPlayer.clearQueue()
        }

        // A rejected play also keeps the session and pointer for retry.
        let rejectedSkipStore = savedFirstTrack()
        let rejectedSkipPlayer = PlayerController(store: rejectedSkipStore, startPolling: false)
        MusicBridge.missing = true
        rejectedSkipPlayer.next()
        try await waitForSkip(rejectedSkipPlayer)
        assert(rejectedSkipStore.currentIndex == 0 && rejectedSkipStore.managedPlaybackActive == true)
        MusicBridge.missing = false
        rejectedSkipPlayer.next()
        try await waitForSkip(rejectedSkipPlayer)
        assert(rejectedSkipStore.currentIndex == 1 && MusicBridge.plays.last == 2872)
        await rejectedSkipPlayer.clearQueue()

        for sameTrackInNativePlaylist in [false, true] {
            let nativeStore = savedFirstTrack()
            let nativePlayer = PlayerController(store: nativeStore, startPolling: false)
            await nativePlayer.playNativePlaylist("explicit-native-list")
            if sameTrackInNativePlaylist { MusicBridge.nativePlaylistContext = "source-list" }
            let localPlays = MusicBridge.plays.count
            let nativeSkips = MusicBridge.nativeNextCount
            nativePlayer.next()
            try await waitForSkip(nativePlayer)
            assert(MusicBridge.plays.count == localPlays && MusicBridge.nativeNextCount == nativeSkips + 1)
            assert(nativeStore.managedPlaybackActive == false)
            MusicBridge.nativePlaylistContext = ""
            await nativePlayer.clearQueue()
        }

        // A new playlist choice while the resume read is in flight supersedes
        // that old click. It must not start a song in either queue afterwards.
        let raceStore = savedFirstTrack()
        let racePlayer = PlayerController(store: raceStore, startPolling: false)
        while MusicBridge.readStarted.consume() {}
        MusicBridge.readDelay = 0.15
        racePlayer.next()
        let raceReadDeadline = Date().addingTimeInterval(3)
        while !MusicBridge.readStarted.consume() {
            assert(Date() < raceReadDeadline)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let localPlaysBeforeRace = MusicBridge.plays.count
        let nativeSkipsBeforeRace = MusicBridge.nativeNextCount
        await racePlayer.playNativePlaylist("new-user-choice")
        try await waitForSkip(racePlayer)
        assert(MusicBridge.plays.count == localPlaysBeforeRace && MusicBridge.nativeNextCount == nativeSkipsBeforeRace)
        MusicBridge.readDelay = 0
        await racePlayer.clearQueue()

        // Old queue files lack the managed flag. Match their selected track
        // and empty native playlist context before safely migrating them.
        _ = savedFirstTrack()
        var legacyJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: skipURL)) as! [String: Any]
        legacyJSON.removeValue(forKey: "managedPlaybackActive")
        try JSONSerialization.data(withJSONObject: legacyJSON).write(to: skipURL, options: .atomic)
        let legacyStore = QueueStore(fileURL: skipURL)
        assert(legacyStore.managedPlaybackActive == nil)
        let legacyPlayer = PlayerController(store: legacyStore, startPolling: false)
        MusicBridge.nativePlaylistContext = "source-list"
        legacyPlayer.next()
        try await waitForSkip(legacyPlayer)
        assert(legacyStore.currentIndex == 1 && MusicBridge.plays.last == 2872)
        await legacyPlayer.clearQueue()
        MusicBridge.nativePlaylistContext = ""
        MusicBridge.nativeNextCount = nativeSkipsBeforeRecoveryTests
        print("PASS: Next recovers キッズリターン→あかねさす across restarts, read/play failure, and legacy queues; native playback remains native")

        UserDefaults.standard.set(false, forKey: "gaplessTakeover")
        let loopURL = listDir.appendingPathComponent("previous-loop.json")
        let loopStore = QueueStore(fileURL: loopURL)
        let loopPlayer = PlayerController(store: loopStore, startPolling: false)
        loopStore.consumeOnPlay = true
        await loopPlayer.playFromPlaylist(album, startAt: 3)
        assert(!loopStore.consumeOnPlay && loopPlayer.displayedRepeat == "all")
        let loopItems = loopStore.items
        MusicBridge.snapshot.position = 30
        await loopPlayer.tick()
        let seeksBeforePrevious = MusicBridge.seekWrites.count
        let nativePreviousBefore = MusicBridge.nativePrevCount
        let previousPlaysStart = MusicBridge.plays.count
        loopPlayer.previous()
        try await waitForSkip(loopPlayer)
        assert(MusicBridge.plays.dropFirst(previousPlaysStart) == [103], "Previous selects the actual previous song after 30 seconds")
        assert(MusicBridge.seekWrites.count == seeksBeforePrevious && MusicBridge.nativePrevCount == nativePreviousBefore)
        let backwardsStart = MusicBridge.plays.count
        loopPlayer.previous(); loopPlayer.previous(); loopPlayer.previous()
        try await waitForSkip(loopPlayer)
        assert(MusicBridge.plays.dropFirst(backwardsStart) == [102, 101, 105], "Previous burst retains every click and wraps first to last")
        let mixedStart = MusicBridge.plays.count
        loopPlayer.next(); loopPlayer.previous(); loopPlayer.next()
        try await waitForSkip(loopPlayer)
        assert(MusicBridge.plays.dropFirst(mixedStart) == [101, 105, 101], "Forward/backward clicks retain FIFO order")
        assert(loopStore.items == loopItems)

        await loopPlayer.play(item: loopStore.items.last!)
        await loopPlayer.advance(automatically: true)
        await loopPlayer.tick()
        assert(MusicBridge.plays.last == 101 && loopStore.currentIndex == 0)
        assert(loopStore.items == loopItems && loopPlayer.displayedRepeat == "all", "A full playlist loop preserves all songs and repeat state")
        assert(QueueStore(fileURL: loopURL).playbackRepeatMode == "all")

        // Failure cannot move the playing pointer backwards before Music accepts.
        await loopPlayer.play(item: loopStore.items[2])
        let pointerBeforeFailedPrevious = loopStore.currentID
        MusicBridge.missing = true
        loopPlayer.previous()
        try await waitForSkip(loopPlayer)
        assert(loopStore.currentID == pointerBeforeFailedPrevious)
        MusicBridge.missing = false
        loopPlayer.previous()
        try await waitForSkip(loopPlayer)
        assert(MusicBridge.plays.last == 102 && loopStore.currentIndex == 1)

        loopPlayer.cycleRepeat() // all -> one
        await loopPlayer.advance(automatically: true)
        assert(MusicBridge.plays.last == 102 && loopStore.currentIndex == 1)
        loopPlayer.previous()
        try await waitForSkip(loopPlayer)
        assert(MusicBridge.plays.last == 101, "Manual Previous moves even in repeat-one")
        loopPlayer.cycleRepeat() // one -> off
        await loopPlayer.play(item: loopStore.items[3])
        await loopPlayer.advance()
        await loopPlayer.tick()
        assert(loopPlayer.displayedRepeat == "off", "Polling and track start preserve an explicit repeat choice")
        await loopPlayer.advance(automatically: true)
        assert(!loopPlayer.owns && loopStore.currentID == nil)
        await loopPlayer.clearQueue()

        await loopPlayer.playFromPlaylist(album, startAt: 2)
        loopPlayer.shutdown()
        let resumedLoopStore = QueueStore(fileURL: loopURL)
        let resumedLoopPlayer = PlayerController(store: resumedLoopStore, startPolling: false)
        MusicBridge.snapshot.position = 30
        resumedLoopPlayer.previous()
        try await waitForSkip(resumedLoopPlayer)
        assert(MusicBridge.plays.last == 102 && resumedLoopPlayer.displayedRepeat == "all")
        await resumedLoopPlayer.clearQueue()
        MusicBridge.snapshot.position = 30
        resumedLoopPlayer.previous()
        try await waitForSkip(resumedLoopPlayer)
        assert(MusicBridge.nativePrevCount == nativePreviousBefore + 1 && MusicBridge.seekWrites.count == seeksBeforePrevious)
        resumedLoopPlayer.shutdown()
        MusicBridge.nativePrevCount = nativePreviousBefore
        UserDefaults.standard.set(true, forKey: "gaplessTakeover")
        print("PASS: real Previous, backward bursts, mixed skips, restart recovery, default playlist loop and explicit off/one")

        UserDefaults.standard.set(false, forKey: "gaplessTakeover")
        let fastStore = QueueStore(fileURL: listDir.appendingPathComponent("fast-burst.json"))
        let fastPlayer = PlayerController(store: fastStore, startPolling: false)
        await fastPlayer.playFromPlaylist(album, startAt: 0)
        await fastPlayer.tick()
        MusicBridge.readDelay = 0.5
        let burstReadsBefore = MusicBridge.stateReadCount
        let burstPlaysBefore = MusicBridge.plays.count
        let burstStarted = Date()
        fastPlayer.next(); fastPlayer.next(); fastPlayer.next()
        try await waitForSkip(fastPlayer)
        assert(MusicBridge.plays.dropFirst(burstPlaysBefore) == [102, 103, 104])
        assert(Date().timeIntervalSince(burstStarted) < 0.5,
               "Transport must not wait for the slow metadata refresh between clicks")
        let refreshDeadline = Date().addingTimeInterval(3)
        while MusicBridge.stateReadCount == burstReadsBefore && Date() < refreshDeadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        assert(MusicBridge.stateReadCount == burstReadsBefore + 1, "A burst should issue one final refresh")
        MusicBridge.readDelay = 0
        // Let the already captured slow read finish before changing mock state.
        try await Task.sleep(nanoseconds: 550_000_000)
        let pointerBeforeFailedBurst = fastStore.currentID
        MusicBridge.missing = true
        fastPlayer.next(); fastPlayer.next(); fastPlayer.next()
        try await waitForSkip(fastPlayer)
        assert(fastStore.currentID == pointerBeforeFailedBurst && fastPlayer.lastError != nil)
        MusicBridge.missing = false
        await fastPlayer.clearQueue()
        fastPlayer.shutdown()
        UserDefaults.standard.set(true, forKey: "gaplessTakeover")
        print("PASS: skip bursts do not wait for metadata, refresh once, and stop safely on a play failure")

        // Media keys arrive packed into data1: key code in the high 16 bits,
        // state in the next byte (0x0A down, 0x0B up), repeat in bit 0.
        func packed(_ code: Int, down: Bool, repeating: Bool = false) -> Int {
            (code << 16) | ((down ? 0x0A : 0x0B) << 8) | (repeating ? 1 : 0)
        }
        assert(MediaKey.decode(data1: packed(17, down: true)) == .init(key: .next, isDown: true, isRepeat: false))
        assert(MediaKey.decode(data1: packed(18, down: false)) == .init(key: .previous, isDown: false, isRepeat: false))
        assert(MediaKey.decode(data1: packed(16, down: true, repeating: true))?.isRepeat == true)
        // Some keyboards send fast / rewind for next / previous.
        assert(MediaKey.decode(data1: packed(19, down: true))?.key.isNext == true)
        assert(MediaKey.decode(data1: packed(20, down: true))?.key.isPrevious == true)
        // Play/pause is decoded but is neither, so it always goes to Music.
        let play = MediaKey.decode(data1: packed(16, down: true))!.key
        assert(!play.isNext && !play.isPrevious)
        // Anything that is not a media key — brightness, volume — is ignored.
        assert(MediaKey.decode(data1: packed(0, down: true)) == nil)
        assert(MediaKey.decode(data1: packed(7, down: true)) == nil)
        print("PASS: media key events decode to next, previous and play")

        // Discord RPC frames: LE opcode, LE length, JSON. Round trip, and a
        // partial frame must wait for the rest rather than misparse.
        var wire = DiscordIPC.encode(opcode: DiscordIPC.frame, json: ["cmd": "SET_ACTIVITY"])!
        assert(Array(wire.prefix(4)) == [1, 0, 0, 0])
        let whole = wire
        var partial = whole.prefix(whole.count - 1)
        assert(DiscordIPC.decode(&partial) == nil, "half a frame is not a frame")
        let frame = DiscordIPC.decode(&wire)
        assert(frame?.opcode == 1 && (frame?.json["cmd"] as? String) == "SET_ACTIVITY" && wire.isEmpty)

        // The activity: Listening, song / artist, a progress bar that matches
        // the position, the album on the cover, and Discord's 2...128 limits.
        let clock = Date(timeIntervalSince1970: 1_000_000)
        let song = MusicTrack(databaseID: 1, name: "ハイキ", artist: "リーガルリリー", album: "kirin", duration: 216)
        let act = DiscordActivity.make(track: song, position: 16, artworkURL: "https://x/600x600bb.jpg", now: clock)
        assert(act["type"] as? Int == 2 && act["details"] as? String == "ハイキ" && act["state"] as? String == "リーガルリリー")
        assert(act["status_display_type"] as? Int == 2, "the status line names the song, not the artist")
        let ts = act["timestamps"] as! [String: Int64]
        assert(ts["start"] == 999_984_000 && ts["end"] == 1_000_200_000, "\(ts)")
        let assets = act["assets"] as! [String: Any]
        assert(assets["large_image"] as? String == "https://x/600x600bb.jpg" && assets["large_text"] as? String == "kirin")
        assert(DiscordActivity.fit("A").count == 2)
        assert(DiscordActivity.fit(String(repeating: "あ", count: 300)).count == 128)
        print("PASS: Discord frames and the listening activity are built to Discord's rules")

        // A duration that is not a usable number must not reach the UI: it ends
        // up as the upper bound of the progress slider's range.
        let GS2 = "\u{1D}", RS2 = "\u{1E}"
        let nasty = ["PLD", ["1", "2", "3", "4"].joined(separator: RS2),
                     ["a", "b", "c", "d"].joined(separator: RS2),
                     ["x", "x", "x", "x"].joined(separator: RS2),
                     ["y", "y", "y", "y"].joined(separator: RS2),
                     ["nan", "inf", "-5", ""].joined(separator: RS2)].joined(separator: GS2)
        let (nastyTracks, _) = LibraryIndex.parse(nasty)
        assert(nastyTracks.count == 4)
        for t in nastyTracks {
            assert(t.duration.isFinite && t.duration >= 0, "bad duration survived: \(t.duration)")
        }
        print("PASS: unusable durations are rejected at the parser")

        // setShuffle(false) deliberately leaves played entries alone, so the
        // order shuffling started from has to be kept for the explicit restore.
        let orderDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: orderDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: orderDir) }
        let orderURL = orderDir.appendingPathComponent("order.json")
        let ordered = QueueStore(fileURL: orderURL)
        ordered.append((1...6).map { MusicTrack(databaseID: $0, name: "o\($0)", artist: "a", album: "b", duration: 10) })
        let ids = ordered.items.map(\QueueItem.id)
        ordered.setShuffle(true)
        _ = ordered.select(ordered.items[4].id)
        ordered.setShuffle(false)
        // Played entries keep their shuffled place — that invariant stays.
        assert(ordered.items.map(\QueueItem.id) != ids || !ordered.canRestoreOriginalOrder)
        let reopened = QueueStore(fileURL: orderURL)
        reopened.restoreOriginalOrder()
        assert(reopened.items.map(\QueueItem.id) == ids, "the original order must survive a restart and a restore")
        assert(!reopened.shuffleActive)
        print("PASS: the pre-shuffle order outlives a restore and a relaunch")

        // Borrowing Music's repeat mode changes another app's settings. If
        // Music quits mid-queue the in-memory record dies with the connection,
        // and the user was left on repeat-one permanently.
        UserDefaults.standard.removeObject(forKey: "borrowedRepeatMode")
        MusicBridge.isRunning = true
        MusicBridge.snapshot = NowPlaying()
        MusicBridge.snapshot.repeatMode = "all"
        MusicBridge.repeatWrites = []
        MusicBridge.plays = []
        MusicBridge.missing = false
        let borrowURL = orderDir.appendingPathComponent("borrow.json")
        let borrowStore = QueueStore(fileURL: borrowURL)
        borrowStore.append((1...3).map { MusicTrack(databaseID: $0, name: "b\($0)", artist: "a", album: "b", duration: 10) })
        let borrower = PlayerController(store: borrowStore, startPolling: false)
        await borrower.startQueueFromTop()
        assert(MusicBridge.snapshot.repeatMode == "one", "the queue takes repeat-one while it drives playback")
        assert(UserDefaults.standard.string(forKey: "borrowedRepeatMode") == "all")
        MusicBridge.isRunning = false
        // A single miss is not trusted as "Music quit": three in a row are.
        await borrower.tick()
        assert(borrower.owns, "one missed check must not drop the queue")
        await borrower.tick()
        await borrower.tick()
        assert(!borrower.owns)
        // A relaunched Music comes back stopped, with nothing loaded.
        MusicBridge.isRunning = true
        MusicBridge.snapshot.state = .stopped
        MusicBridge.snapshot.track = nil
        await borrower.tick()
        assert(MusicBridge.snapshot.repeatMode == "all",
               "Music quitting mid-queue must not keep the user on repeat-one")
        assert(UserDefaults.standard.string(forKey: "borrowedRepeatMode") == nil)
        UserDefaults.standard.removeObject(forKey: "borrowedRepeatMode")
        print("PASS: the borrowed repeat mode is returned even if Music quits mid-queue")

        // If the queue lets go while Music keeps playing its current song, the
        // queue must take that song back, or Music loops it forever.
        let adoptStore = QueueStore(fileURL: orderDir.appendingPathComponent("adopt.json"))
        adoptStore.append((1...3).map { MusicTrack(databaseID: 50 + $0, name: "a\($0)", artist: "a", album: "b", duration: 100) })
        MusicBridge.snapshot = NowPlaying()
        MusicBridge.snapshot.repeatMode = "off"
        UserDefaults.standard.removeObject(forKey: "borrowedRepeatMode")
        let adopter = PlayerController(store: adoptStore, startPolling: false)
        await adopter.startQueueFromTop()
        MusicBridge.isRunning = false
        for _ in 0..<3 { await adopter.tick() }
        assert(!adopter.owns)
        MusicBridge.isRunning = true
        MusicBridge.snapshot.state = .playing
        MusicBridge.snapshot.track = MusicTrack(databaseID: 51, name: "a1", artist: "a", album: "b", duration: 100)
        MusicBridge.snapshot.position = 10
        await adopter.tick()
        assert(adopter.owns, "Music playing the queue's current song is taken back")
        MusicBridge.plays = []
        MusicBridge.snapshot.position = 11; await adopter.tick()
        MusicBridge.snapshot.position = 12; await adopter.tick()
        MusicBridge.snapshot.position = 99.8; await adopter.tick()
        assert(MusicBridge.plays == [52], "and moves on to the next song: \(MusicBridge.plays)")
        await adopter.clearQueue()
        print("PASS: a dropped queue is taken back instead of Music looping one song")

        // Music's mute property cannot be written through AppleScript, so a
        // mute is a volume drop that has to remember the level to come back to.
        UserDefaults.standard.removeObject(forKey: "mutedVolume")
        MusicBridge.snapshot = NowPlaying()
        MusicBridge.snapshot.volume = 63
        MusicBridge.volumeWrites = []
        let muteStore = QueueStore(fileURL: orderDir.appendingPathComponent("mute.json"))
        MusicBridge.isRunning = true
        var muter = PlayerController(store: muteStore, startPolling: false)
        await muter.tick()   // the controller can only remember a level it has read
        // The volume write is dispatched, so wait for it rather than assuming
        // a fixed number of yields is enough.
        func settle(until condition: @escaping () -> Bool) async {
            for _ in 0..<200 {
                if condition() { return }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        muter.toggleMute()
        await settle { MusicBridge.snapshot.volume == 0 }
        assert(muter.isMuted && MusicBridge.snapshot.volume == 0, "mute silences Music")

        // A restart must not strand the user at zero with the level forgotten.
        muter = PlayerController(store: muteStore, startPolling: false)
        assert(muter.isMuted, "the muted level survives a relaunch")
        muter.toggleMute()
        await settle { MusicBridge.snapshot.volume == 63 }
        assert(!muter.isMuted && MusicBridge.snapshot.volume == 63, "unmute restores the level")

        // Choosing a volume by hand cancels the mute instead of leaving a
        // stale level that a later unmute would snap back to.
        muter.toggleMute()
        await settle { MusicBridge.snapshot.volume == 0 }
        muter.setVolume(40)
        await settle { MusicBridge.snapshot.volume == 40 }
        assert(!muter.isMuted && MusicBridge.snapshot.volume == 40)
        UserDefaults.standard.removeObject(forKey: "mutedVolume")
        print("PASS: mute remembers the volume, survives a relaunch and yields to the slider")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("queue.json")
        let tracks = (1...6).map { MusicTrack(databaseID: $0, name: "曲 \($0)", artist: "Artist", album: "Album", duration: 100) }
        let store = QueueStore(fileURL: url)
        store.append(tracks)
        let original = store.items.map(\.id)
        _ = store.select(original[1])
        store.remove(ids: [original[1]])
        assert(store.items.count == 6, "Currently playing item must be retained")
        store.setShuffle(true)
        assert(Array(store.items.prefix(2).map(\.id)) == Array(original.prefix(2)))
        store.reshuffle()
        store.append([tracks[0]])
        let restored = QueueStore(fileURL: url)
        assert(restored.shuffleActive && restored.currentID == original[1])
        restored.setShuffle(false)
        assert(Array(restored.items.prefix(6).map(\.id)) == original)
        assert(restored.items.count == 7)
        restored.consumeOnPlay = true
        assert(restored.advance()?.id == original[2])
        assert(!restored.items.contains { $0.id == original[1] })
        restored.setShuffle(true)
        _ = restored.advance()
        let history = Array(restored.items.prefix((restored.currentIndex ?? -1) + 1).map(\.id))
        restored.setShuffle(false)
        assert(Array(restored.items.prefix(history.count).map(\.id)) == history,
               "Turning shuffle off must not replay or skip already visited entries")
        restored.clearUpcoming()
        assert(restored.upcoming.isEmpty)
        restored.setShuffle(true)
        restored.replaceAll(with: tracks)
        assert(!restored.shuffleActive && restored.currentID == nil)
        restored.clearAll()
        assert(QueueStore(fileURL: url).items.isEmpty, "Immediate quit/reload must preserve latest mutation")
        print("PASS: persistence, shuffle restore, consume, clearing, replacement")

        let player = PlayerController(store: store, startPolling: false)
        let previousGapless = player.gaplessTakeover
        defer { player.gaplessTakeover = previousGapless; player.shutdown() }
        player.gaplessTakeover = true
        MusicBridge.snapshot.repeatMode = "all"
        await player.startQueueFromTop()
        assert(player.owns && player.displayedRepeat == "all")
        assert(MusicBridge.snapshot.repeatMode == "one")
        await player.tick()
        assert(player.owns)
        await player.advance()
        assert(store.currentIndex == 1)
        await player.clearQueue()
        assert(!player.owns && MusicBridge.snapshot.repeatMode == "all")
        print("PASS: queue takeover, skip, clear restores repeat")

        store.append(tracks)
        MusicBridge.missing = true
        await player.startQueueFromTop()
        assert(!player.owns && player.lastError != nil)
        assert(MusicBridge.snapshot.repeatMode == "all")
        MusicBridge.missing = false
        MusicBridge.delay = 0.1
        let start = Task { await player.startQueueFromTop() }
        await Task.yield()
        await player.tick()
        await start.value
        MusicBridge.delay = 0
        await player.tick()
        assert(player.owns && player.lastError == nil)
        print("PASS: missing track releases repeat; polling cannot interrupt a transition")

        // The engine only trusts a track once it has been seen playing and
        // moving forward mid-song; a jump straight from 0 to the end is the
        // stale reading that used to skip songs. Play a little first.
        func confirmPlaying(_ p: PlayerController) async {
            MusicBridge.snapshot.state = .playing
            MusicBridge.snapshot.position = 10; await p.tick()
            MusicBridge.snapshot.position = 11; await p.tick()
        }

        await player.clearQueue()
        store.append([tracks[0]])
        MusicBridge.snapshot.repeatMode = "off"
        await player.startQueueFromTop()
        await player.tick()
        await confirmPlaying(player)
        MusicBridge.snapshot.position = 99.9
        await player.tick()
        assert(!player.owns && MusicBridge.snapshot.state == .paused)
        assert(MusicBridge.snapshot.repeatMode == "off")
        print("PASS: final track stops and restores repeat")

        await player.startQueueFromTop()
        await player.tick()
        let previousCount = MusicBridge.plays.count
        player.cycleRepeat() // off -> all
        await confirmPlaying(player)
        MusicBridge.snapshot.position = 99.9
        await player.tick()
        assert(player.owns && MusicBridge.plays.count == previousCount + 1)
        player.cycleRepeat() // all -> one
        await player.tick()
        await confirmPlaying(player)
        MusicBridge.snapshot.position = 99.9
        await player.tick()
        assert(player.owns && MusicBridge.plays.count == previousCount + 2)
        await player.clearQueue()
        print("PASS: queue repeat-all and repeat-one")

        store.replaceAll(with: tracks)
        await player.startQueueFromTop()
        MusicBridge.delay = 0.06
        player.next()
        player.next()
        player.next()
        while player.pendingSkipCount > 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        assert(store.currentIndex == 3, "Every next click must be applied, even during track transitions")
        MusicBridge.delay = 0
        await player.clearQueue()
        store.append(tracks)
        player.next()
        while player.pendingSkipCount > 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        assert(MusicBridge.nativeNextCount == 1 && !player.owns,
               "Native Music playback must not be hijacked by a dormant queue")
        print("PASS: rapid next clicks are preserved; native playback uses native next")

        assert(!player.shuffleTargetsQueue, "A saved custom queue must not redirect Music shuffle")
        await player.playNative(tracks[1])
        assert(!player.owns && MusicBridge.plays.last == tracks[1].databaseID)
        await player.playNativePlaylist("playlist-test")
        assert(!player.owns && MusicBridge.lastPlaylist == "playlist-test")
        print("PASS: search and playlists use native Music playback")

        let volumeBurstStart = MusicBridge.volumeWrites.count
        for volume in 0...100 { player.setVolume(volume) }
        let volumeBurstDeadline = Date().addingTimeInterval(3)
        while MusicBridge.volumeWrites.count == volumeBurstStart && Date() < volumeBurstDeadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        assert(MusicBridge.volumeWrites.count == volumeBurstStart + 1 && MusicBridge.volumeWrites.last == 100,
               "Slider changes must coalesce instead of flooding the command lane")
        print("PASS: volume bursts send only the latest intent")

        // Every click affects the final parity, but each burst sends only one
        // write. In-flight reads and writes must not reset that pending intent.
        func settleShuffle() async throws {
            let deadline = Date().addingTimeInterval(5)
            while player.isShuffleChanging && Date() < deadline {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            assert(!player.isShuffleChanging, "Shuffle worker failed to settle")
        }
        func awaitSignal(_ signal: TestSignal) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !signal.consume() {
                assert(Date() < deadline, "Music adapter never started the expected operation")
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        for initial in [false, true] {
            for clicks in [10, 11] {
                MusicBridge.snapshot.shuffle = initial
                await player.tick()
                let count = MusicBridge.shuffleWrites.count
                for _ in 0..<clicks { player.toggleShuffle() }
                let expected = clicks % 2 == 0 ? initial : !initial
                assert(player.shuffleIsOn == expected)
                await player.tick() // Poll old state while the write is pending.
                assert(player.shuffleIsOn == expected, "Polling reset pending intent")
                try await settleShuffle()
                assert(player.shuffleIsOn == expected && MusicBridge.snapshot.shuffle == expected)
                assert(MusicBridge.shuffleWrites.count == count + 1, "Burst issued redundant writes")
            }
        }
        print("PASS: shuffle burst parity from both states; pending intent survives polls")

        MusicBridge.snapshot.shuffle = false
        await player.tick()
        while MusicBridge.shuffleStarted.consume() {}
        MusicBridge.shuffleDelay = 0.12
        player.toggleShuffle()
        try await awaitSignal(MusicBridge.shuffleStarted)
        player.toggleShuffle() // Change intent while the first Music write waits.
        try await settleShuffle()
        assert(!player.shuffleIsOn && !MusicBridge.snapshot.shuffle)
        MusicBridge.shuffleDelay = 0
        print("PASS: latest shuffle click wins during a delayed write")

        player.toggleShuffle()
        while MusicBridge.readStarted.consume() {}
        MusicBridge.readDelay = 0.3
        let stalePoll = Task { await player.tick() }
        try await awaitSignal(MusicBridge.readStarted)
        try await settleShuffle()
        await stalePoll.value
        MusicBridge.readDelay = 0
        assert(player.shuffleIsOn && MusicBridge.snapshot.shuffle, "Stale poll overwrote acknowledged state")
        print("PASS: late polling results cannot undo shuffle confirmation")

        MusicBridge.failShuffle = true
        player.toggleShuffle()
        try await settleShuffle()
        assert(player.shuffleIsOn && player.lastError != nil, "Failure must restore confirmed state")
        MusicBridge.failShuffle = false
        player.toggleShuffle()
        try await settleShuffle()
        assert(!player.shuffleIsOn && !MusicBridge.snapshot.shuffle)
        assert(player.lastError == nil)
        print("PASS: shuffle failure rolls back; the next click retries")

        let trackBeforeAdd = MusicBridge.snapshot.track
        let playsBeforeAdd = MusicBridge.plays.count
        let revisionBeforeAdd = player.queueRevision
        await player.enqueueNativePlaylist("whole-playlist")
        assert(MusicBridge.enqueuedPlaylists == ["whole-playlist"])
        assert(MusicBridge.snapshot.track == trackBeforeAdd && MusicBridge.plays.count == playsBeforeAdd)
        assert(player.lastAddedPlaylistID == "whole-playlist" && player.addingPlaylistID == nil)
        assert(player.queueRevision == revisionBeforeAdd + 1)
        MusicBridge.failQueueAdd = true
        await player.enqueueNativePlaylist("unavailable-playlist")
        assert(player.lastAddedPlaylistID == nil && player.lastError != nil && player.addingPlaylistID == nil)
        MusicBridge.failQueueAdd = false
        assert(QueueInsertionPosition.menuChoice(["再生", "次に再生", "キューに追加"])?.position == .end)
        assert(QueueInsertionPosition.menuChoice(["再生", "次に再生"])?.position == .next)
        assert(QueueInsertionPosition.menuChoice(["Play", "Play Last"])?.position == .end)
        assert(QueueInsertionPosition.menuChoice(["Play", "プレイリストに追加", "ライブラリから削除"]) == nil)
        print("PASS: whole playlist enqueue preserves playback and excludes replacement/deletion actions")

        let displays: [CGRect] = [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            CGRect(x: 1440, y: -300, width: 1920, height: 1080),
            CGRect(x: 0, y: 900, width: 1280, height: 720),
            CGRect(x: 0, y: -600, width: 1024, height: 600)
        ]
        for screen in displays {
            let visible = CGRect(x: screen.minX, y: screen.minY + 40,
                                 width: screen.width, height: screen.height - 65)
            for x in [screen.minX + 2, screen.midX, screen.maxX - 2] {
                let click = CGPoint(x: x, y: screen.maxY - 12)
                let wrongScreenButton = CGRect(x: 6000, y: 8000, width: 200, height: 24)
                let frame = PanelPlacement.frame(click: click, button: wrongScreenButton,
                                                  screen: screen, visible: visible)
                assert(visible.contains(frame), "Panel escaped clicked display")
                assert(frame.width <= visible.width && frame.height <= visible.height)
            }
        }
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let anchor = CGRect(x: 900, y: 876, width: 200, height: 24)
        let placed = PanelPlacement.frame(click: CGPoint(x: 950, y: 888), button: anchor,
                                          screen: displays[0], visible: visible)
        assert(placed.midX == anchor.midX && placed.maxY <= anchor.minY)
        print("PASS: panel placement on five display arrangements, both edges and stale screen anchors")
    }
}
