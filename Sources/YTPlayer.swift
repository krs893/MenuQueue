import Foundation
import Combine

/// Follows YouTube Music and sends it commands.
///
/// One state read a second (each is a single osascript run across the open
/// YouTube Music tabs). Commands are optimistic: the panel updates at once,
/// and the next read confirms or corrects it.
@MainActor
final class YTPlayer: ObservableObject {
    @Published private(set) var state = YTState()
    @Published private(set) var available = false
    @Published var lastError: String?

    private var loop: Task<Void, Never>?
    private var reading = false
    /// Reads started before a command finished must not overwrite the
    /// optimistic value it just set.
    private var revision = 0

    init(startPolling: Bool = true) {
        if startPolling { start() }
    }

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let interval: Double = self.available ? 1.0 : 3.0
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() { loop?.cancel() }

    func refresh() async {
        guard !reading else { return }
        reading = true
        defer { reading = false }
        let seen = revision
        let outcome = await Task.detached(priority: .utility) { Result { try YTMusicBridge.readState() } }.value
        guard seen == revision else { return }
        switch outcome {
        case .success(let s):
            available = true
            if state != s { state = s }
            if lastError != nil { lastError = nil }
        case .failure(let error):
            available = false
            if state != YTState() { state = YTState() }
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            if lastError != message { lastError = message }
        }
    }

    // MARK: Commands

    private func send(_ action: YTMusicBridge.Action, optimistic: ((inout YTState) -> Void)? = nil) {
        revision += 1
        if let optimistic { var s = state; optimistic(&s); state = s }
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try YTMusicBridge.perform(action) }
            }.value
            if case .failure(let error) = outcome {
                lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            // Give the page a moment to act, then read what it did.
            try? await Task.sleep(nanoseconds: 250_000_000)
            revision += 1
            await refresh()
        }
    }

    func togglePlayPause() { send(.playPause) { $0.playing.toggle() } }
    func next() { send(.next) }
    func previous() { send(.previous) }
    func shuffle() { send(.shuffle) }
    func cycleRepeat() {
        send(.cycleRepeat) { s in
            s.repeatMode = ["off": "all", "all": "one", "one": "off"][s.repeatMode] ?? "off"
        }
    }
    func toggleMute() { send(.toggleMute) { $0.muted.toggle() } }
    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        send(.seek(seconds)) { $0.position = seconds }
    }
    func setVolume(_ level: Int) { send(.volume(level)) { $0.volume = level; $0.muted = false } }
    func jump(to index: Int) { send(.jump(index)) { $0.currentIndex = index } }
}
