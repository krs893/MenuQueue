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
    @Published private(set) var pendingSkipCount = 0
    @Published private(set) var addingPlaylistID: String?
    @Published private(set) var lastAddedPlaylistID: String?
    @Published private(set) var lastInsertionPosition: QueueInsertionPosition?
    @Published private(set) var queueRevision = 0
    private var skipTask: Task<Void, Never>?
    @Published private var requestedShuffle: Bool?
    private var shuffleTask: Task<Void, Never>?
    private var shuffleRequestVersion = 0
    var isShuffleChanging: Bool { requestedShuffle != nil }

    /// Borrow Music's repeat-one while the queue drives playback. Off by
    /// default: Music resets the repeat mode whenever a track is started, so
    /// the borrow did not reliably take, and when it did it was a change to
    /// the user's own setting. The queue no longer needs it — the next track is
    /// handed over just before the current one ends (see `handoffLead`).
    @Published var gaplessTakeover: Bool = UserDefaults.standard.object(forKey: "gaplessTakeover") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(gaplessTakeover, forKey: "gaplessTakeover")
            Task {
                guard !transitioning else { return }
                if gaplessTakeover && owns { await applyRepeatOne() }
                else { await restoreRepeat() }
            }
        }
    }

    let store: QueueStore

    private var expectedDBID: Int?
    private var savedRepeat: String?
    /// Mirrors `savedRepeat` on disk. Borrowing Music's repeat mode is a change
    /// to someone else's app, and the in-memory copy dies with the process: if
    /// Music quits mid-queue, or this app is force quit, nothing is left to
    /// hand the setting back and the user is stuck on repeat-one for good.
    private static let borrowedRepeatKey = "borrowedRepeatMode"
    private var pendingRepeatRestore: String? {
        get { UserDefaults.standard.string(forKey: Self.borrowedRepeatKey) }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: Self.borrowedRepeatKey) }
            else { UserDefaults.standard.removeObject(forKey: Self.borrowedRepeatKey) }
        }
    }
    private var lastPosition: Double = 0
    private var advancing = false
    private var transitioning = false
    private var polling = false
    private var revision = 0
    private var expectedUntil: Date?
    private var observer: NSObjectProtocol?

    var displayedRepeat: String { owns ? (savedRepeat ?? now.repeatMode) : now.repeatMode }
    private var loopTask: Task<Void, Never>?
    private var artworkDBID: Int?
    private var pollInterval: Double = 1.0

    init(store: QueueStore, startPolling: Bool = true) {
        self.store = store
        guard startPolling else { return }
        observer = DistributedNotificationCenter.default().addObserver(
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
        skipTask?.cancel()
        shuffleTask?.cancel()
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        // Termination must not leave an unawaited task restoring repeat after exit.
        if let saved = savedRepeat ?? pendingRepeatRestore, MusicBridge.isRunning {
            try? MusicBridge.setRepeat(saved)
            pendingRepeatRestore = nil
        }
    }

    // MARK: - Polling

    private func bridge<T>(_ work: @escaping @Sendable () throws -> T) async -> T? {
        do {
            return try await Task.detached(priority: .userInitiated) { try work() }.value
        } catch {
            await MainActor.run { self.lastError = error.localizedDescription }
            return nil
        }
    }

    func tick() async {
        guard !polling, !transitioning else { return }
        polling = true
        defer { polling = false }
        let snapshotRevision = revision
        let running = MusicBridge.isRunning
        musicRunning = running
        guard running else {
            now = NowPlaying()
            artwork = nil
            artworkDBID = nil
            pollInterval = 3.0
            owns = false
            expectedDBID = nil
            // Only the in-memory copy goes; pendingRepeatRestore survives so
            // the borrowed mode is returned once Music comes back.
            savedRepeat = nil
            return
        }

        guard let np = await bridge({ try MusicBridge.nowPlaying() }) else {
            pollInterval = 2.0
            return
        }

        guard snapshotRevision == revision, !transitioning else { return }
        // Music is back (or this is a fresh launch) and we are not driving it:
        // give back anything a previous session borrowed and never returned.
        if !owns, savedRepeat == nil, pendingRepeatRestore != nil {
            await restoreRepeat()
        }
        let previousState = now.state
        now = np

        // Artwork only when the track actually changes — it is the expensive call.
        if np.track?.databaseID != artworkDBID {
            artworkDBID = np.track?.databaseID
            let img = await bridge({ MusicBridge.artworkOfCurrentTrack() }) ?? nil
            if np.track?.databaseID == artworkDBID { artwork = img }
        }

        guard snapshotRevision == revision, !transitioning else { return }
        if owns { await evaluateAdvance(np, previousState: previousState) }
        guard snapshotRevision == revision else { return }

        lastPosition = np.position
        pollInterval = computeInterval(np)
    }

    /// How long before the end of a track the next one is handed to Music.
    ///
    /// What Music does at the end of a single track started from a script
    /// depends on the user's repeat mode and on whatever is left in Music's own
    /// queue: it may stop, loop, or wander off. Getting in first avoids all of
    /// that. The window has to be wider than one poll plus one AppleScript
    /// round trip, or a poll can land either side of it and miss — at 0.15 s
    /// it did, on a real track with repeat set to "all". The cost is at most
    /// half a second of the tail, which is nearly always fade or silence.
    static let handoffLead: Double = 0.5

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
            if let expectedUntil, Date() < expectedUntil { return }
            await releaseOwnership()
            return
        }
        if np.track?.databaseID == expectedDBID { expectedUntil = nil }
        if np.state == .stopped && previousState.isPlaying {
            await advance(automatically: true)
            return
        }
        guard let d = np.track?.duration, d > 0, np.state.isPlaying else { return }
        let remaining = d - np.position
        if remaining <= Self.handoffLead {
            await advance(automatically: true)
            return
        }
        // Repeat-one looped us back to the top: the track finished.
        if lastPosition > 2, np.position < lastPosition - 2, (d - lastPosition) < 2.5 {
            await advance(automatically: true)
        }
    }

    // MARK: - Queue-driven playback

    func play(item: QueueItem) async {
        guard !transitioning, !advancing,
              store.items.contains(where: { $0.id == item.id }) else { return }
        await start(item)
    }

    private func start(_ item: QueueItem) async {
        guard !transitioning else { return }
        transitioning = true
        revision += 1
        defer { transitioning = false }
        lastError = nil
        await rememberUserRepeat()
        let dbID = item.track.databaseID
        let playlistID = item.track.sourcePlaylistID
        let ok = await bridge({ try MusicBridge.play(databaseID: dbID, playlistID: playlistID) })
        guard ok == true else {
            if ok == false { lastError = "ライブラリに見つかりません: \(item.track.name)" }
            await releaseOwnership()
            return
        }
        // After the play, which has just reset the repeat mode to off.
        await applyRepeatOne()
        _ = store.select(item.id)
        expectedDBID = dbID
        expectedUntil = Date().addingTimeInterval(3)
        owns = true
        lastPosition = 0
        pollInterval = 0.3
    }

    func advance(automatically: Bool = false) async {
        guard !advancing, !transitioning else { return }
        advancing = true
        defer { advancing = false }
        if automatically, displayedRepeat == "one",
           let item = store.items.first(where: { $0.id == store.currentID }) {
            await start(item)
            return
        }
        let repeatAll = displayedRepeat == "all"
        if let next = store.advance() {
            await start(next)
        } else if repeatAll, let first = store.items.first {
            await start(first)
        } else {
            revision += 1
            _ = await bridge({ try MusicBridge.pause() })
            await releaseOwnership()
        }
    }

    /// Picking a track out of a playlist should carry on through the rest of it.
    ///
    /// Music cannot be made to do that from a script. Playing a single track
    /// drops the playlist context — `current playlist` comes back unset and
    /// `next track` just restarts the same song — and `play <playlist>`, which
    /// does keep the context, always starts from the top. Skipping forward from
    /// the top would reach the right track, but every skipped song would be
    /// recorded against the user's listening history.
    ///
    /// So the playlist becomes this app's queue, starting at the chosen track,
    /// and the controller hands Music the next one when each ends.
    func playFromPlaylist(_ tracks: [MusicTrack], startAt index: Int) async {
        guard tracks.indices.contains(index), !transitioning, !advancing else { return }
        store.replaceAll(with: tracks)
        await play(item: store.items[index])
    }

    func startQueueFromTop() async {
        guard let first = store.items.first else { return }
        await play(item: first)
    }

    func clearQueue() async {
        guard !transitioning, !advancing else { return }
        transitioning = true
        defer { transitioning = false }
        revision += 1
        store.clearAll()
        await releaseOwnership()
    }

    func replaceQueue(with tracks: [MusicTrack]) async {
        guard !transitioning, !advancing else { return }
        store.replaceAll(with: tracks)
        await startQueueFromTop()
    }

    private func releaseOwnership() async {
        owns = false
        expectedDBID = nil
        expectedUntil = nil
        await restoreRepeat()
    }

    /// Records the user's repeat mode so it can be handed back later.
    ///
    /// This has to happen before a track is started, and the borrow itself
    /// after: `play <track>` resets Music's repeat mode to off. Borrowing first
    /// meant the play immediately undid it, and recording afterwards would
    /// have remembered that "off" instead of what the user actually had.
    private func rememberUserRepeat() async {
        guard gaplessTakeover, savedRepeat == nil else { return }
        guard let current = await bridge({ try MusicBridge.nowPlaying() }) else { return }
        // Never record "one" as the mode to go back to: that is the mode
        // being borrowed, and a leftover entry from an earlier crash would
        // otherwise make it permanent.
        savedRepeat = current.repeatMode == "one" ? (pendingRepeatRestore ?? "off") : current.repeatMode
        pendingRepeatRestore = savedRepeat
    }

    private func applyRepeatOne() async {
        guard gaplessTakeover else { return }
        await rememberUserRepeat()
        guard savedRepeat != nil else { return }
        _ = await bridge({ try MusicBridge.setRepeat("one") })
    }

    private func restoreRepeat() async {
        guard let saved = savedRepeat ?? pendingRepeatRestore else { return }
        let restored: Void? = await bridge({ try MusicBridge.setRepeat(saved) })
        if restored != nil {
            savedRepeat = nil
            pendingRepeatRestore = nil
        }
    }

    // Search and playlists operate on Music's actual queue.
    func playNative(_ track: MusicTrack) async {
        guard !transitioning else { return }
        transitioning = true
        revision += 1
        defer { transitioning = false }
        await releaseOwnership()
        lastError = nil
        let ok = await bridge { try MusicBridge.play(databaseID: track.databaseID,
                                                     playlistID: track.sourcePlaylistID) }
        if ok == false { lastError = "曲を見つけられません: \(track.name)" }
        pollInterval = 0.3
    }

    func playNativePlaylist(_ id: String) async {
        guard !transitioning else { return }
        transitioning = true
        revision += 1
        defer { transitioning = false }
        await releaseOwnership()
        lastError = nil
        _ = await bridge { try MusicBridge.playPlaylist(id) }
        pollInterval = 0.3
    }

    func refreshNativeQueue() { queueRevision += 1 }

    func enqueueNativePlaylist(_ id: String) async {
        guard addingPlaylistID == nil else { return }
        addingPlaylistID = id
        lastAddedPlaylistID = nil
        lastInsertionPosition = nil
        lastError = nil
        defer { addingPlaylistID = nil }
        if let position = await bridge({ try MusicBridge.enqueuePlaylist(id) }) {
            lastAddedPlaylistID = id
            lastInsertionPosition = position
            queueRevision += 1
        }
    }

    // MARK: - Transport exposed to the UI

    /// Music reports `stopped` with no current track when its queue has run
    /// out or been cleared. Its own Play menu item is disabled in that state,
    /// so `play` and `playpause` do nothing at all — the button looked broken.
    /// Fall back to this app's queue when it has something, and otherwise say
    /// there is nothing to play rather than swallowing the click.
    var canStartPlayback: Bool {
        guard musicRunning else { return false }
        if now.track != nil { return true }
        return !store.items.isEmpty
    }

    var playbackUnavailableReason: String? {
        guard musicRunning else { return "ミュージックが起動していません" }
        guard now.track == nil, store.items.isEmpty else { return nil }
        return "Musicに再生中の曲がありません。ライブラリタブからプレイリストを再生してください"
    }

    func togglePlayPause() {
        Task {
            guard !transitioning, !advancing else { return }
            if now.track == nil, !store.items.isEmpty {
                await startQueueFromTop()
            } else {
                _ = await bridge({ try MusicBridge.playPause() })
            }
            await tick()
        }
    }

    func next() {
        // Preserve rapid clicks while Music is processing a previous command.
        pendingSkipCount += 1
        guard skipTask == nil else { return }
        skipTask = Task {
            defer { skipTask = nil; pendingSkipCount = 0 }
            while pendingSkipCount > 0 && !Task.isCancelled {
                while transitioning || advancing {
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    if Task.isCancelled { return }
                }
                lastError = nil
                if owns {
                    await advance()
                } else {
                    revision += 1
                    _ = await bridge({ try MusicBridge.nativeNext() })
                }
                pendingSkipCount -= 1
                await tick()
            }
        }
    }

    func previous() {
        Task {
            guard !transitioning, !advancing else { return }
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
        guard seconds.isFinite, !transitioning else { return }
        revision += 1
        now.position = seconds
        lastPosition = seconds
        Task { _ = await bridge({ try MusicBridge.seek(to: seconds) }) }
    }

    /// Music's `mute` property is read-only through AppleScript — writing it
    /// fails with error 9038 — so muting means dropping the volume to zero and
    /// remembering what it was. The remembered level is persisted: being left
    /// silent with no way back after a restart would be worse than the extra
    /// state.
    private static let mutedVolumeKey = "mutedVolume"
    private var storedMuteLevel: Int? {
        get {
            guard UserDefaults.standard.object(forKey: Self.mutedVolumeKey) != nil else { return nil }
            return UserDefaults.standard.integer(forKey: Self.mutedVolumeKey)
        }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: Self.mutedVolumeKey) }
            else { UserDefaults.standard.removeObject(forKey: Self.mutedVolumeKey) }
        }
    }

    /// True when this app silenced Music, or when Music reports itself muted.
    var isMuted: Bool { storedMuteLevel != nil || now.muted }

    func toggleMute() {
        if let level = storedMuteLevel {
            storedMuteLevel = nil
            setVolume(level == 0 ? 25 : level)
            return
        }
        // Nothing to come back to if it is already silent; use a sensible level.
        let level = now.volume > 0 ? now.volume : 25
        storedMuteLevel = level
        setVolume(0)
    }

    func setVolume(_ v: Int) {
        // Moving the slider is an explicit volume choice, so it cancels a mute
        // rather than leaving a stale level to be restored later.
        if v > 0, storedMuteLevel != nil { storedMuteLevel = nil }
        now.volume = v
        revision += 1
        Task { _ = await bridge({ try MusicBridge.setVolume(v) }) }
    }

    /// With a queue loaded, shuffling Music.app would do nothing — we hand it
    /// single tracks — so the button shuffles our own list instead.
    var shuffleTargetsQueue: Bool { owns && !store.items.isEmpty }

    var shuffleIsOn: Bool { shuffleTargetsQueue ? store.shuffleActive : (requestedShuffle ?? now.shuffle) }

    func toggleShuffle() {
        if shuffleTargetsQueue {
            store.setShuffle(!store.shuffleActive)
            return
        }
        // Toggle the user's latest intent, never a poll that may be out of date.
        lastError = nil
        requestedShuffle = !(requestedShuffle ?? now.shuffle)
        shuffleRequestVersion += 1
        revision += 1
        guard shuffleTask == nil else { return }
        shuffleTask = Task {
            defer { shuffleTask = nil; requestedShuffle = nil }
            while !Task.isCancelled {
                let version = shuffleRequestVersion
                // Coalesce a burst into its final on/off state. Only one Music
                // write can be in flight; newer clicks remain pending meanwhile.
                do { try await Task.sleep(nanoseconds: 120_000_000) }
                catch { return }
                while transitioning || advancing {
                    do { try await Task.sleep(nanoseconds: 30_000_000) }
                    catch { return }
                }
                guard !Task.isCancelled else { return }
                if version != shuffleRequestVersion { continue }
                guard let target = requestedShuffle else { return }
                let applied: Void? = await bridge { try MusicBridge.setShuffle(target) }
                // Discard polls captured before this write finished, including
                // polls that were started after the user's latest click.
                revision += 1
                guard !Task.isCancelled else { return }
                if applied != nil {
                    now.shuffle = target
                    if requestedShuffle == target { return }
                } else if version == shuffleRequestVersion {
                    // Leave the last confirmed state visible; a new click can
                    // retry normally. bridge() retains the error for the UI.
                    return
                }
            }
        }
    }

    func cycleRepeat() {
        let order = ["off", "all", "one"]
        guard !transitioning else { return }
        let idx = order.firstIndex(of: displayedRepeat) ?? 0
        let target = order[(idx + 1) % order.count]
        now.repeatMode = target
        if owns && gaplessTakeover { savedRepeat = target } else { Task { _ = await bridge({ try MusicBridge.setRepeat(target) }) } }
        if !owns { Task { await tick() } }
    }

    func launchMusic() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MusicBridge.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
