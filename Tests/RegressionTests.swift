import Foundation

@main
struct RegressionTests {
    @MainActor static func main() async throws {
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

        await player.clearQueue()
        store.append([tracks[0]])
        MusicBridge.snapshot.repeatMode = "off"
        await player.startQueueFromTop()
        await player.tick()
        MusicBridge.snapshot.position = 99.9
        await player.tick()
        assert(!player.owns && MusicBridge.snapshot.state == .paused)
        assert(MusicBridge.snapshot.repeatMode == "off")
        print("PASS: final track stops and restores repeat")

        await player.startQueueFromTop()
        await player.tick()
        let previousCount = MusicBridge.plays.count
        player.cycleRepeat() // off -> all
        MusicBridge.snapshot.position = 99.9
        await player.tick()
        assert(player.owns && MusicBridge.plays.count == previousCount + 1)
        player.cycleRepeat() // all -> one
        await player.tick()
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
