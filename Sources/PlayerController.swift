import Foundation
import AppKit
import Combine

/// Drives Music.app from the app's own queue.
///
/// Music.app exposes no scriptable Up Next, so the only way to own the running
/// order is to hand it one track at a time. A local timer schedules the next
/// track from the reported playback position. Artwork loads independently so
/// a slow image request cannot hold up state updates or that timer.
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
    private enum SkipDirection: String { case next, previous }
    private var pendingSkips: [SkipDirection] = []
    private var volumeTask: Task<Void, Never>?
    private var requestedVolume: Int?
    private static let bridgeQueue = DispatchQueue(label: "jp.menuqueue.control-work", qos: .userInitiated,
                                                    attributes: .concurrent)
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

    /// Injected so tests can move time forward without sleeping.
    var clock: () -> Date = { Date() }

    /// When the current queue track was handed to Music.
    private var startedAt: Date?
    /// Whether the current queue track is known to be the one actually
    /// playing. Until then nothing may advance the queue automatically.
    ///
    /// Right after a track is started Music answers with a mix of old and new:
    /// one sample 392 ms after `play` had the previous song's name with the
    /// new song's position. The reverse mix — the new name with the old song's
    /// near-the-end position — reads as "this track is about to finish", and
    /// the engine used to act on it at once and skip the song the user had
    /// just picked. So a track is only trusted once it is seen by id with its
    /// position actually moving forward, not near the end.
    private var confirmed = false
    private var confirmPosition: Double?
    private var notRunningPolls = 0
    /// The scheduled hand-off to the next track; see `scheduleHandoff`.
    private var handoffTask: Task<Void, Never>?
    private var handoffAt: Date?
    private var observer: NSObjectProtocol?

    private var hasManagedQueueContext: Bool {
        if owns { return true }
        guard store.mayResumeManagedPlayback, let id = store.currentID,
              let current = store.items.first(where: { $0.id == id }) else { return false }
        return current.track.databaseID == now.track?.databaseID
    }

    var displayedRepeat: String {
        hasManagedQueueContext ? (store.playbackRepeatMode ?? savedRepeat ?? now.repeatMode) : now.repeatMode
    }
    private var loopTask: Task<Void, Never>?
    private var isShutdown = false
    private final class ArtworkRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }
    }
    private var artworkRequest: ArtworkRequest?
    private var artworkTask: Task<Void, Never>?
    private static let artworkQueue = DispatchQueue(label: "jp.menuqueue.now-playing-artwork", qos: .utility)
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
        guard !isShutdown else { return }
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
        isShutdown = true
        revision += 1
        loopTask?.cancel()
        skipTask?.cancel()
        volumeTask?.cancel()
        shuffleTask?.cancel()
        cancelHandoff()
        artworkRequest?.cancel()
        artworkTask?.cancel()
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
            return try await withCheckedThrowingContinuation { done in
                Self.bridgeQueue.async {
                    do { done.resume(returning: try work()) }
                    catch { done.resume(throwing: error) }
                }
            }
        } catch {
            EventLog.shared.note("bridge error  \(error.localizedDescription)")
            await MainActor.run { self.lastError = error.localizedDescription }
            return nil
        }
    }

    func tick() async {
        guard !isShutdown, !polling, !transitioning else { return }
        polling = true
        defer { polling = false }
        let snapshotRevision = revision
        var running = MusicBridge.isRunning
        // One miss is not "Music quit": wait for it to be gone on consecutive
        // polls before dropping the queue.
        if running { notRunningPolls = 0 } else { notRunningPolls += 1 }
        if !running, notRunningPolls < 3, owns {
            pollInterval = 1.0
            return
        }
        musicRunning = running
        guard running else {
            now = NowPlaying()
            artworkRequest?.cancel()
            artworkTask?.cancel()
            artworkTask = nil
            artwork = nil
            artworkDBID = nil
            pollInterval = 3.0
            if owns { EventLog.shared.note("release  Music quit") }
            cancelHandoff()
            confirmed = false
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
        // Music is playing the queue's current song but the queue let go of it
        // (a restart, or a lost connection): take it back, or Music will loop
        // that one song instead of moving on through the playlist.
        if !owns, np.state.isPlaying, store.mayResumeManagedPlayback,
           let id = store.currentID, let item = store.items.first(where: { $0.id == id }),
           item.track.databaseID == np.track?.databaseID {
            owns = true
            expectedDBID = item.track.databaseID
            confirmed = false
            confirmPosition = nil
            startedAt = clock()
            expectedUntil = clock().addingTimeInterval(8)
            // Pick the borrowed repeat mode back up, so repeat-one that this app
            // set is not mistaken for the user's own choice.
            if savedRepeat == nil { savedRepeat = pendingRepeatRestore }
            EventLog.shared.note("adopt  \(item.track.name)  (Music is playing the queue's current song)")
        }
        // Music is back (or this is a fresh launch) and we are not driving it:
        // give back anything a previous session borrowed and never returned.
        if !owns, savedRepeat == nil, pendingRepeatRestore != nil {
            await restoreRepeat()
        }
        let previousState = now.state
        now = np

        updateArtwork(for: np.track?.databaseID)

        guard snapshotRevision == revision, !transitioning else { return }
        if owns { await evaluateAdvance(np, previousState: previousState) }
        guard snapshotRevision == revision else { return }

        lastPosition = np.position
        pollInterval = computeInterval(np)
    }

    /// Images are optional; transport and state polling must never await them.
    private func updateArtwork(for databaseID: Int?) {
        guard databaseID != artworkDBID else { return }
        artworkRequest?.cancel()
        artworkTask?.cancel()
        artworkTask = nil
        artworkDBID = databaseID
        artwork = nil
        guard let databaseID else { return }
        let request = ArtworkRequest()
        artworkRequest = request
        artworkTask = Task { [weak self] in
            let image = await withCheckedContinuation { (done: CheckedContinuation<NSImage?, Never>) in
                Self.artworkQueue.async {
                    guard !request.isCancelled else { return done.resume(returning: nil) }
                    done.resume(returning: MusicBridge.artworkOfCurrentTrack())
                }
            }
            guard !Task.isCancelled, let self, self.artworkDBID == databaseID else { return }
            self.artwork = image
            self.artworkTask = nil
            self.artworkRequest = nil
        }
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

    /// One poll a second is plenty now that the hand-off is timed locally.
    ///
    /// The engine used to poll every 100 ms in the last seconds of a track to
    /// catch the end. But every poll is a dozen Apple Events and Music takes
    /// about 35 ms to answer each, so that was Music being asked something
    /// thirty-odd times a second near the end of every song — enough to make
    /// playback stumble — while each answer was already 200 ms stale.
    private func computeInterval(_ np: NowPlaying) -> Double {
        guard np.state.isPlaying else { return 2.0 }
        guard owns else { return 1.0 }
        return confirmed ? 1.0 : 0.5
    }

    private func evaluateAdvance(_ np: NowPlaying, previousState: PlayerState) async {
        let now = clock()
        let sinceStart = startedAt.map { now.timeIntervalSince($0) } ?? .infinity
        if !confirmed, let deadline = expectedUntil, now >= deadline {
            lastError = "再生を開始できませんでした: \(store.items.first { $0.id == store.currentID }?.track.name ?? "曲")。もう一度再生してください。"
            await releaseOwnership("queued track never began playing", keepQueueSession: true)
            return
        }

        // A track other than ours, or nothing at all.
        if np.track?.databaseID != expectedDBID {
            if !confirmed {
                // Still switching over: Music reports the previous song for a
                // moment. Only give up if ours never turns up.
                if let expectedUntil, now < expectedUntil { return }
                await releaseOwnership("Music never started the queued track", keepQueueSession: true)
                return
            }
            if np.track == nil, np.state == .stopped {
                // Music reached the end of our track before the hand-off fired.
                EventLog.shared.note("advance  ended before hand-off (stopped)")
                await advance(automatically: true)
                return
            }
            // Something else is playing: the user changed it in Music itself.
            await releaseOwnership("Music moved to another track (\(np.track?.name ?? "none"))")
            return
        }

        guard let d = np.track?.duration, d > 0 else { return }
        let remaining = d - np.position

        if !confirmed {
            EventLog.shared.note(String(format: "poll   unconfirmed  pos=%.2f rem=%.2f first=%@ state=%@",
                                        np.position, remaining,
                                        confirmPosition.map { String(format: "%.2f", $0) } ?? "nil",
                                        "\(np.state)"))
            // Ours by id. Trust it once the position is seen to move forward
            // from a believable starting point — not a stale reading left over
            // from the end of the previous song.
            if let first = confirmPosition, np.position > first + 0.2, remaining > 3 {
                confirmed = true
                expectedUntil = nil
                EventLog.shared.note(String(format: "confirm  playing at %.1fs (%.1fs after start)", np.position, sinceStart))
            } else if remaining > 3 {
                confirmPosition = np.position
            }
            if !confirmed { return }
        }

        switch np.state {
        case .playing, .fastForwarding, .rewinding:
            // Repeat-one (or Music on its own) looped our track back to the top:
            // treat it as finished.
            if lastPosition > 2, np.position < lastPosition - 2, (d - lastPosition) < 3 {
                EventLog.shared.note("advance  track looped")
                await advance(automatically: true)
                return
            }
            if remaining <= Self.handoffLead {
                EventLog.shared.note(String(format: "advance  %.2fs left at poll", remaining))
                await advance(automatically: true)
                return
            }
            scheduleHandoff(after: remaining - Self.handoffLead)
        case .stopped:
            if previousState.isPlaying {
                EventLog.shared.note("advance  ended before hand-off (stopped)")
                await advance(automatically: true)
            }
        default:
            // Paused: the clock has stopped, so must the hand-off.
            cancelHandoff()
        }
    }

    /// Hands the next track to Music just before this one ends.
    ///
    /// Timed on this side from the last position Music reported, and re-timed
    /// on every poll, so a pause, a seek or drift is corrected within a second.
    /// That replaces catching the end by polling fast, which both hammered
    /// Music and still read positions a fifth of a second old.
    private func scheduleHandoff(after delay: TimeInterval) {
        let at = clock().addingTimeInterval(max(delay, 0))
        // Re-arming every second for the same moment is pointless churn.
        if let handoffAt, abs(handoffAt.timeIntervalSince(at)) < 0.25, handoffTask != nil { return }
        handoffTask?.cancel()
        handoffAt = at
        EventLog.shared.note(String(format: "timer  hand-off in %.2fs", delay))
        let expected = expectedDBID
        handoffTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard self.owns, self.confirmed, self.expectedDBID == expected,
                  self.now.state.isPlaying else { return }
            self.handoffTask = nil
            self.handoffAt = nil
            EventLog.shared.note("advance  hand-off timer")
            await self.advance(automatically: true)
        }
    }

    private func cancelHandoff() {
        handoffTask?.cancel()
        handoffTask = nil
        handoffAt = nil
    }

    // MARK: - Queue-driven playback

    func play(item: QueueItem) async {
        guard !transitioning, !advancing,
              store.items.contains(where: { $0.id == item.id }) else { return }
        await start(item)
    }

    @discardableResult
    private func start(_ item: QueueItem, consumingPrevious: Bool = false) async -> Bool {
        guard !transitioning else { return false }
        transitioning = true
        revision += 1
        defer { transitioning = false }
        lastError = nil
        await rememberUserRepeat()
        let dbID = item.track.databaseID
        let playlistID = item.track.sourcePlaylistID
        EventLog.shared.note("request  \(item.track.name)  [db \(dbID)]")
        let ok = await bridge({ try MusicBridge.play(databaseID: dbID, playlistID: playlistID) })
        guard ok == true else {
            if ok == false { lastError = "ライブラリに見つかりません: \(item.track.name)" }
            await releaseOwnership("could not start \(item.track.name)", keepQueueSession: true)
            return false
        }
        // After the play, which has just reset the repeat mode to off.
        await applyRepeatOne()
        if consumingPrevious { store.commitAdvance(to: item.id) }
        else { _ = store.select(item.id) }
        store.setManagedPlayback(true)
        expectedDBID = dbID
        cancelHandoff()
        startedAt = clock()
        confirmed = false
        confirmPosition = nil
        // Long enough for a cloud track to buffer: positions sat at 0.00 for
        // over a second after `play` before they started to move.
        expectedUntil = clock().addingTimeInterval(8)
        owns = true
        lastPosition = 0
        pollInterval = 0.5
        EventLog.shared.note("start  \(item.track.name)  [db \(dbID)]  queue \((store.currentIndex ?? -1) + 1)/\(store.items.count)")
        return true
    }

    @discardableResult
    func advance(automatically: Bool = false) async -> Bool {
        guard !advancing, !transitioning else { return false }
        advancing = true
        defer { advancing = false }
        if automatically, displayedRepeat == "one",
           let item = store.items.first(where: { $0.id == store.currentID }) {
            return await start(item)
        }
        let repeatAll = displayedRepeat == "all"
        if let next = store.nextCandidate {
            return await start(next, consumingPrevious: true)
        } else if repeatAll, let first = store.items.first {
            return await start(first, consumingPrevious: true)
        } else {
            store.finishCurrent()
            revision += 1
            _ = await bridge({ try MusicBridge.pause() })
            await releaseOwnership("end of queue")
            return true
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
        store.consumeOnPlay = false
        store.setPlaybackRepeatMode("all")
        await play(item: store.items[index])
    }

    func shuffleExistingPlaylist(_ id: String) async {
        guard !transitioning, !advancing else { return }
        transitioning = true
        revision += 1
        defer { transitioning = false }
        await releaseOwnership()
        lastError = nil
        _ = await bridge { try MusicBridge.shufflePlaylist(id) }
        pollInterval = 0.3
    }

    func playShuffled(_ tracks: [MusicTrack]) async {
        guard !tracks.isEmpty, !transitioning, !advancing else { return }
        store.replaceAll(with: tracks)
        store.consumeOnPlay = false
        store.setPlaybackRepeatMode("all")
        store.setShuffle(true)
        await startQueueFromTop()
    }

    func startQueueFromTop() async {
        guard let first = store.items.first else { return }
        await play(item: first)
    }

    func resumeCurrentQueue() async {
        guard let id = store.currentID, let item = store.items.first(where: { $0.id == id }) else { return }
        await play(item: item)
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

    private func releaseOwnership(_ reason: String = "", keepQueueSession: Bool = false) async {
        if owns, !reason.isEmpty { EventLog.shared.note("release  \(reason)") }
        cancelHandoff()
        confirmed = false
        startedAt = nil
        owns = false
        if !keepQueueSession { store.setManagedPlayback(false) }
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
        queueSkip(.next)
    }

    func previous() {
        queueSkip(.previous)
    }

    private func queueSkip(_ direction: SkipDirection) {
        guard !isShutdown else { return }
        EventLog.shared.note("\(direction.rawValue)  clicked (owns=\(owns), queue=\(store.currentIndex.map(String.init) ?? "none"))")
        // Preserve rapid clicks while Music is processing a previous command.
        pendingSkips.append(direction)
        pendingSkipCount += 1
        guard skipTask == nil else { return }
        skipTask = Task {
            defer { skipTask = nil; pendingSkipCount = 0; pendingSkips.removeAll() }
            while let direction = pendingSkips.first, !Task.isCancelled {
                while transitioning || advancing {
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    if Task.isCancelled { return }
                }
                lastError = nil
                var useQueue = owns
                if !useQueue {
                    guard let decision = await shouldResumeQueueForSkip() else { return }
                    useQueue = decision
                }
                var succeeded = true
                if useQueue {
                    if direction == .next { succeeded = await advance() }
                    else if let previous = store.previousCandidate(wrapping: displayedRepeat == "all") {
                        succeeded = await start(previous)
                    }
                } else {
                    revision += 1
                    let applied: Void?
                    if direction == .next { applied = await bridge({ try MusicBridge.nativeNext() }) }
                    else { applied = await bridge({ try MusicBridge.nativePrev() }) }
                    succeeded = applied != nil
                }
                guard succeeded else { return }
                pendingSkips.removeFirst()
                pendingSkipCount -= 1
            }
            // Transport does not wait for metadata between clicks. Refresh
            // once after the burst, without holding up a new button press.
            if !Task.isCancelled { Task { await tick() } }
        }
    }

    private func shouldResumeQueueForSkip() async -> Bool? {
        guard store.mayResumeManagedPlayback,
              let id = store.currentID, let item = store.items.first(where: { $0.id == id }) else { return false }
        let decisionRevision = revision
        guard let snapshot = await bridge({ try MusicBridge.nowPlaying() }) else { return nil }
        guard revision == decisionRevision, !transitioning, !advancing,
              store.currentID == id, store.mayResumeManagedPlayback else { return nil }
        let matches = snapshot.track?.databaseID == item.track.databaseID
        let stopped = snapshot.state == .stopped && snapshot.track == nil
        guard matches || stopped else {
            store.setManagedPlayback(false)
            return false
        }
        // Music can report the source playlist even for a single-track play
        // whose native Next only restarts that song. A known managed session,
        // or a legacy selection still in its source list, must use our queue.
        guard let playlist = await bridge({ try MusicBridge.currentPlaylistID() }) else { return nil }
        guard revision == decisionRevision, !transitioning, !advancing,
              store.currentID == id, store.mayResumeManagedPlayback else { return nil }
        if store.managedPlaybackActive == nil, !playlist.isEmpty,
           playlist != item.track.sourcePlaylistID {
            store.setManagedPlayback(false)
            return false
        }
        EventLog.shared.note("skip  resume saved queue after Music/app restart")
        return true
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
        let target = max(0, min(100, v))
        now.volume = target
        requestedVolume = target
        revision += 1
        guard volumeTask == nil else { return }
        volumeTask = Task {
            defer { volumeTask = nil; requestedVolume = nil }
            do { try await Task.sleep(nanoseconds: 80_000_000) }
            catch { return }
            while !Task.isCancelled, let volume = requestedVolume {
                _ = await bridge { try MusicBridge.setVolume(volume) }
                revision += 1
                if requestedVolume == volume { return }
            }
        }
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
        if hasManagedQueueContext, store.playbackRepeatMode != nil {
            store.setPlaybackRepeatMode(target)
            if owns && gaplessTakeover { savedRepeat = target }
            return
        }
        if owns && gaplessTakeover { savedRepeat = target } else { Task { _ = await bridge({ try MusicBridge.setRepeat(target) }) } }
        if !owns { Task { await tick() } }
    }

    func launchMusic() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MusicBridge.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
