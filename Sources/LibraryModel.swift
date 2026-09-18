import Foundation
import Combine

/// Library search + playlist browsing, used by the "追加" tab.
@MainActor
final class LibraryModel: ObservableObject {

    @Published var query: String = ""
    @Published var results: [MusicTrack] = []
    @Published var playlists: [PlaylistInfo] = []
    @Published var selectedPlaylist: PlaylistInfo?
    @Published var playlistTracks: [MusicTrack] = []
    @Published var isSearching = false
    @Published var error: String?

    private var searchTask: Task<Void, Never>?

    func searchDebounced() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { results = []; isSearching = false; return }
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            let found = await Task.detached(priority: .userInitiated) {
                (try? MusicBridge.search(q)) ?? []
            }.value
            guard !Task.isCancelled else { return }
            self.results = found
            self.isSearching = false
        }
    }

    func loadPlaylists() {
        Task { [weak self] in
            let lists = await Task.detached(priority: .userInitiated) {
                (try? MusicBridge.playlists()) ?? []
            }.value
            self?.playlists = lists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    func loadTracks(of playlist: PlaylistInfo) {
        selectedPlaylist = playlist
        playlistTracks = []
        Task { [weak self] in
            let pid = playlist.id
            let tracks = await Task.detached(priority: .userInitiated) {
                (try? MusicBridge.tracks(inPlaylist: pid)) ?? []
            }.value
            guard self?.selectedPlaylist?.id == pid else { return }
            self?.playlistTracks = tracks
        }
    }
}

/// Up Next scraping, kept separate so a failure never blocks the queue tab.
@MainActor
final class UpNextModel: ObservableObject {
    @Published var rows: [UpNextRow] = []
    @Published var error: String?
    @Published var loading = false
    @Published var lastRead: Date?

    func refresh() {
        guard !loading else { return }
        loading = true
        error = nil
        Task { [weak self] in
            let outcome: Result<[UpNextRow], Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try UpNextReader.read()) }
                catch { return .failure(error) }
            }.value
            guard let self else { return }
            self.loading = false
            switch outcome {
            case .success(let rows):
                self.rows = rows
                self.lastRead = Date()
            case .failure(let err):
                self.rows = []
                self.error = (err as? LocalizedError)?.errorDescription ?? "\(err)"
            }
        }
    }
}
