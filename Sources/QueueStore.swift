import Foundation
import Combine

struct QueueItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var track: MusicTrack
}

/// The app's own queue. Music.app has no scriptable "Up Next", so this list is
/// the source of truth and the player controller feeds Music.app one track at
/// a time from it.
@MainActor
final class QueueStore: ObservableObject {

    @Published private(set) var items: [QueueItem] = []
    /// The queue entry the controller believes is currently playing.
    @Published var currentID: UUID?
    /// Drop entries once they have been played instead of keeping a pointer.
    @Published var consumeOnPlay: Bool = false { didSet { save() } }
    /// Shuffle applies to this list, not to Music.app. Music.app's own shuffle
    /// has no effect while we are feeding it one track at a time, so shuffling
    /// here is the only version that both works and is visible.
    @Published private(set) var shuffleActive = false

    private var preShuffleOrder: [UUID]?

    private var saveWorkItem: DispatchWorkItem?

    private static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuQueue", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("queue.json")
    }

    private struct Persisted: Codable {
        var items: [QueueItem]
        var currentID: UUID?
        var consumeOnPlay: Bool?
        var shuffleActive: Bool?
        var preShuffleOrder: [UUID]?
    }

    init() { load() }

    var currentIndex: Int? {
        guard let currentID else { return nil }
        return items.firstIndex { $0.id == currentID }
    }

    /// Entries after the one playing — i.e. what actually plays next.
    var upcoming: [QueueItem] {
        guard let i = currentIndex else { return items }
        return Array(items.dropFirst(i + 1))
    }

    // MARK: Mutations

    func append(_ tracks: [MusicTrack]) {
        items.append(contentsOf: tracks.map { QueueItem(track: $0) })
        save()
    }

    /// Insert directly after the track that is playing.
    func playNext(_ tracks: [MusicTrack]) {
        let insertAt = (currentIndex.map { $0 + 1 }) ?? 0
        items.insert(contentsOf: tracks.map { QueueItem(track: $0) }, at: min(insertAt, items.count))
        save()
    }

    func remove(ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) && $0.id != currentID }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Shuffles the entries after the one playing, and restores the original
    /// running order when switched back off.
    func setShuffle(_ on: Bool) {
        if on {
            preShuffleOrder = items.map(\.id)
            if let i = currentIndex, i + 1 < items.count {
                var tail = Array(items[(i + 1)...])
                tail.shuffle()
                items = Array(items[0...i]) + tail
            } else if currentIndex == nil {
                items.shuffle()
            }
        } else if let order = preShuffleOrder {
            var rank: [UUID: Int] = [:]
            for (i, id) in order.enumerated() { rank[id] = i }
            let known = items.filter { rank[$0.id] != nil }
                             .sorted { rank[$0.id]! < rank[$1.id]! }
            // Anything added while shuffled has no original position; keep it
            // at the end in the order it was added.
            let added = items.filter { rank[$0.id] == nil }
            items = known + added
            preShuffleOrder = nil
        }
        shuffleActive = on
        save()
    }

    func reshuffle() {
        guard shuffleActive else { return }
        let saved = preShuffleOrder
        setShuffle(true)
        preShuffleOrder = saved ?? preShuffleOrder
        save()
    }

    func clearUpcoming() {
        guard let i = currentIndex else { items.removeAll(); save(); return }
        items.removeSubrange((i + 1)...)
        save()
    }

    func clearAll() {
        items.removeAll()
        currentID = nil
        save()
    }

    func replaceAll(with tracks: [MusicTrack]) {
        items = tracks.map { QueueItem(track: $0) }
        currentID = nil
        save()
    }

    /// Advances the pointer and returns the entry that should start playing.
    func advance() -> QueueItem? {
        guard let i = currentIndex else {
            let first = items.first
            currentID = first?.id
            save()
            return first
        }
        let nextIndex = i + 1
        guard nextIndex < items.count else {
            if consumeOnPlay { items.remove(at: i) }
            currentID = nil
            save()
            return nil
        }
        let next = items[nextIndex]
        if consumeOnPlay { items.remove(at: i) }
        currentID = next.id
        save()
        return next
    }

    func previous() -> QueueItem? {
        guard let i = currentIndex, i > 0 else { return nil }
        let prev = items[i - 1]
        currentID = prev.id
        save()
        return prev
    }

    func select(_ id: UUID) -> QueueItem? {
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        currentID = id
        save()
        return item
    }

    // MARK: Persistence (debounced — drags fire a lot of mutations)

    private func save() {
        saveWorkItem?.cancel()
        let snapshot = Persisted(items: items, currentID: currentID,
                                 consumeOnPlay: consumeOnPlay,
                                 shuffleActive: shuffleActive,
                                 preShuffleOrder: preShuffleOrder)
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: QueueStore.storeURL, options: .atomic)
        }
        saveWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func load() {
        guard let data = try? Data(contentsOf: QueueStore.storeURL),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        items = p.items
        currentID = p.currentID
        consumeOnPlay = p.consumeOnPlay ?? false
        shuffleActive = p.shuffleActive ?? false
        preShuffleOrder = p.preShuffleOrder
    }
}
