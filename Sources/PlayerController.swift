import Foundation
import AppKit
import Combine

/// Drives Music.app from the app's own queue.
///
/// Music.app exposes no scriptable Up Next, so the only way to own the running
/// order is to hand it one track at a time. Two things make that seamless:
///
///  * while we own playback we set Music's repeat mode to `one`, so when a
///    track ends Music loops it instead of jumping into some unrelated album;
///  * polling tightens to 100 ms in the last seconds of a track, so we start
///    the next queue entry within a fraction of a second of the end.
///
/// The previous repeat setting is restored as soon as we let go.
@MainActor
final class PlayerController: ObservableObject {

    @Published var now = NowPlaying()
    @Published var artwork: NSImage?
    @Published var musicRunning = false
    @Published var owns = false
    @Published var lastError: String?

    @Published var gaplessTakeover: Bool = UserDefaults.standard.object(forKey: "gaplessTakeover") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(gaplessTakeover, forKey: "gaplessTakeover")
            if !gaplessTakeover { restoreRepeat() }
        }
    }

    let store: QueueStore

    private var expectedDBID: Int?
    private var savedRepeat: String?
    private var lastPosition: Double = 0
    private var advancing = false
    private var loopTask: Task<Void, Never>?
    private var artworkDBID: Int?
    private var pollInterval: Double = 1.0

    init(store: QueueStore) {
        self.store = store
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        start()
    }

    func start() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                let interval = self.pollInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func shutdown() {
        loopTask?.cancel()
        restoreRepeat()
    }

    // MARK: - Polling

    private func bridge<T>(_ work: @escaping @Sendable () throws -> T) async -> T? {
        do {
            return try await Task.detached(priority: .userInitiated) { try work() }.value
        } catch {
            await MainActor.run { self.lastError = "\(error)" }
            return nil
        }
    }

    func tick() async {
        let running = MusicBridge.isRunning
        musicRunning = running
        guard running else {
            now = NowPlaying()
            artwork = nil
            artworkDBID = nil
            pollInterval = 3.0
            if owns { owns = false; savedRepeat = nil }
            return
        }

        guard let np = await bridge({ try MusicBridge.nowPlaying() }) else {
            pollInterval = 2.0
            return
        }

        let previousState = now.state
        now = np
        lastError = nil

        // Artwork only when the track actually changes — it is the expensive call.
        if np.track?.databaseID != artworkDBID {
            artworkDBID = np.track?.databaseID
            let img = await bridge({ MusicBridge.artworkOfCurrentTrack() }) ?? nil
            if np.track?.databaseID == artworkDBID { artwork = img }
        }

        if owns { await evaluateAdvance(np, previousState: previousState) }

        lastPosition = np.position
        pollInterval = computeInterval(np)
    }

    private func computeInterval(_ np: NowPlaying) -> Double {
        guard np.state.isPlaying else { return 2.0 }
        guard owns, let d = np.track?.duration, d > 0 else { return 1.0 }
        let remaining = d - np.position
        if remaining <= 4 { return 0.1 }
        if remaining <= 15 { return 0.5 }
        return 1.0
    }

    private func evaluateAdvance(_ np: NowPlaying, previousState: PlayerState) async {
        // Music jumped to a track we did not ask for: release the queue.
        if let t = np.track, let expected = expectedDBID, t.databaseID != expected {
            releaseOwnership()
            return
        }
        if np.state == .stopped && previousState.isPlaying {
            await advance()
            return
        }
        guard let d = np.track?.duration, d > 0, np.state.isPlaying else { return }
        let remaining = d - np.position
        if remaining <= 0.35 {
            await advance()
            return
        }
        // Repeat-one looped us back to the top: the track finished.
        if lastPosition > 2, np.position < lastPosition - 2, (d - lastPosition) < 2.5 {
            await advance()
        }
    }

    // MARK: - Queue-driven playback

    func play(item: QueueItem) async {
        _ = store.select(item.id)
        await start(item)
    }

    private func start(_ item: QueueItem) async {
        expectedDBID = item.track.databaseID
        owns = true
        lastPosition = 0
        applyRepeatOne()
        let dbID = item.track.databaseID
        let ok = await bridge({ try MusicBridge.play(databaseID: dbID) }) ?? false
        if ok != true {
            lastError = "ライブラリに見つかりません: \(item.track.name)"
        }
        pollInterval = 0.3
    }

    func advance() async {
        guard !advancing else { return }
        advancing = true
        defer { advancing = false }

        if let next = store.advance() {
            await start(next)
        } else {
            releaseOwnership()
            _ = await bridge({ try MusicBridge.pause() })
        }
    }

    func startQueueFromTop() async {
        guard let first = store.items.first else { return }
        await play(item: first)
    }

    private func releaseOwnership() {
        owns = false
        expectedDBID = nil
        restoreRepeat()
    }

    private func applyRepeatOne() {
        guard gaplessTakeover else { return }
        if savedRepeat == nil { savedRepeat = now.repeatMode.isEmpty ? "off" : now.repeatMode }
        let mode = "one"
        Task.detached { try? MusicBridge.setRepeat(mode) }
    }

    private func restoreRepeat() {
        guard let saved = savedRepeat else { return }
        savedRepeat = nil
        Task.detached { try? MusicBridge.setRepeat(saved) }
    }

    // MARK: - Transport exposed to the UI

    func togglePlayPause() {
        Task { _ = await bridge({ try MusicBridge.playPause() }); await tick() }
    }

    func next() {
        Task {
            if owns || !store.upcoming.isEmpty {
                if !owns, let first = store.items.first, store.currentID == nil {
                    await play(item: first)
                } else {
                    await advance()
                }
            } else {
                _ = await bridge({ try MusicBridge.nativeNext() })
            }
            await tick()
        }
    }

    func previous() {
        Task {
            if now.position > 3 {
                _ = await bridge({ try MusicBridge.seek(to: 0) })
            } else if owns, let prev = store.previous() {
                await start(prev)
            } else {
                _ = await bridge({ try MusicBridge.nativePrev() })
            }
            await tick()
        }
    }

    func seek(to seconds: Double) {
        now.position = seconds
        lastPosition = seconds
        Task { _ = await bridge({ try MusicBridge.seek(to: seconds) }) }
    }

    func setVolume(_ v: Int) {
        now.volume = v
        Task { _ = await bridge({ try MusicBridge.setVolume(v) }) }
    }

    /// With a queue loaded, shuffling Music.app would do nothing — we hand it
    /// single tracks — so the button shuffles our own list instead.
    var shuffleTargetsQueue: Bool { !store.items.isEmpty }

    var shuffleIsOn: Bool { shuffleTargetsQueue ? store.shuffleActive : now.shuffle }

    func toggleShuffle() {
        if shuffleTargetsQueue {
            store.setShuffle(!store.shuffleActive)
        } else {
            let target = !now.shuffle
            now.shuffle = target
            Task { _ = await bridge({ try MusicBridge.setShuffle(target) }); await tick() }
        }
    }

    func cycleRepeat() {
        let order = ["off", "all", "one"]
        let idx = order.firstIndex(of: now.repeatMode) ?? 0
        let target = order[(idx + 1) % order.count]
        now.repeatMode = target
        if owns { savedRepeat = target } else { Task { _ = await bridge({ try MusicBridge.setRepeat(target) }) } }
        if !owns { Task { await tick() } }
    }

    func launchMusic() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MusicBridge.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
