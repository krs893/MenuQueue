import Foundation
import Combine
import SwiftUI

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
    @Published private(set) var currentID: UUID?
    /// Drop entries once they have been played instead of keeping a pointer.
    @Published var consumeOnPlay: Bool = false { didSet { save() } }
    /// Shuffle applies to this list, not to Music.app. Music.app's own shuffle
    /// has no effect while we are feeding it one track at a time, so shuffling
    /// here is the only version that both works and is visible.
    @Published private(set) var shuffleActive = false

    private var preShuffleOrder: [UUID]?
    /// The last order shuffling started from, kept after a restore so the list
    /// can still be put back in full. See `restoreOriginalOrder()`.
    private var shuffleOriginOrder: [UUID]?

    @Published private(set) var persistenceError: String?
    private let fileURL: URL
    private var loading = false

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
        var shuffleOriginOrder: [UUID]?
    }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.storeURL
        load()
    }

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
        guard on != shuffleActive else { return }
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
            let boundary = currentIndex.map { $0 + 1 } ?? 0
            let history = Array(items.prefix(boundary))
            let pending = Array(items.dropFirst(boundary))
            let known = pending.filter { rank[$0.id] != nil }
                               .sorted { rank[$0.id]! < rank[$1.id]! }
            // Anything added while shuffled has no original position; keep it
            // at the end in the order it was added.
            let added = pending.filter { rank[$0.id] == nil }
            items = history + known + added
            // Entries already visited keep their shuffled position on purpose,
            // so switching shuffle off neither replays nor skips them. That
            // leaves the played prefix out of the original order for good, so
            // hold on to the original: without it a later restore has nothing
            // to work from, and the list can never be put back.
            shuffleOriginOrder = order
            preShuffleOrder = nil
        }
        shuffleActive = on
        save()
    }

    /// Puts every entry back in the order shuffling started from, including
    /// the part already played. `setShuffle(false)` deliberately leaves played
    /// entries where they are; this is the explicit "I want the album order
    /// back" action, and it may move the playing track's index.
    var canRestoreOriginalOrder: Bool {
        guard let order = preShuffleOrder ?? shuffleOriginOrder else { return false }
        var rank: [UUID: Int] = [:]
        for (i, id) in order.enumerated() { rank[id] = i }
        let known = items.filter { rank[$0.id] != nil }
        return known.map { rank[$0.id]! } != known.map { rank[$0.id]! }.sorted()
    }

    func restoreOriginalOrder() {
        guard let order = preShuffleOrder ?? shuffleOriginOrder else { return }
        var rank: [UUID: Int] = [:]
        for (i, id) in order.enumerated() { rank[id] = i }
        let known = items.filter { rank[$0.id] != nil }
                         .sorted { rank[$0.id]! < rank[$1.id]! }
        let added = items.filter { rank[$0.id] == nil }
        items = known + added
        shuffleActive = false
        preShuffleOrder = nil
        shuffleOriginOrder = nil
        save()
    }

    func reshuffle() {
        guard shuffleActive else { return }
        let saved = preShuffleOrder
        shuffleActive = false
        setShuffle(true)
        preShuffleOrder = saved
        save()
    }

    func clearUpcoming() {
        guard let i = currentIndex else { items.removeAll(); save(); return }
        items.removeSubrange((i + 1)...)
        save()
    }

    func clearAll() {
        items.removeAll()
        shuffleActive = false
        preShuffleOrder = nil
        shuffleOriginOrder = nil
        currentID = nil
        save()
    }

    func replaceAll(with tracks: [MusicTrack]) {
        items = tracks.map { QueueItem(track: $0) }
        shuffleActive = false
        preShuffleOrder = nil
        shuffleOriginOrder = nil
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

    // MARK: Persistence
    // Writes are serialized on the main actor. Each user action is durably saved
    // before returning, including an immediate Quit after editing the queue.
    private func save() {
        guard !loading else { return }
        let snapshot = Persisted(items: items, currentID: currentID,
                                 consumeOnPlay: consumeOnPlay,
                                 shuffleActive: shuffleActive,
                                 preShuffleOrder: preShuffleOrder,
                                 shuffleOriginOrder: shuffleOriginOrder)
        do {
            let data = try JSONEncoder().encode(snapshot)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = "キューの保存に失敗しました: \(error.localizedDescription)"
        }
    }

    private func load() {
        loading = true
        defer { loading = false }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let p = try JSONDecoder().decode(Persisted.self, from: data)
            items = p.items
            currentID = items.contains { $0.id == p.currentID } ? p.currentID : nil
            consumeOnPlay = p.consumeOnPlay ?? false
            shuffleActive = p.shuffleActive ?? false
            preShuffleOrder = p.preShuffleOrder
            shuffleOriginOrder = p.shuffleOriginOrder
        } catch {
            persistenceError = "保存済みキューを読み込めません: \(error.localizedDescription)"
        }
    }
}
