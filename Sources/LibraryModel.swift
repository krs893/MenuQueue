import Foundation
import Combine

@MainActor
final class LibraryModel: ObservableObject {
    @Published var query = ""
    @Published var results: [MusicTrack] = []
    @Published var playlists: [PlaylistInfo] = []
    @Published var selectedPlaylist: PlaylistInfo?
    @Published var playlistTracks: [MusicTrack] = []
    @Published var isSearching = false
    @Published var isLoadingPlaylists = false
    @Published var isLoadingTracks = false
    @Published var searchError: String?
    @Published var playlistError: String?
    private var searchTask: Task<Void, Never>?
    private var trackRevision = 0

    func searchDebounced() {
        searchTask?.cancel()
        searchError = nil
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { results = []; isSearching = false; return }
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try MusicBridge.search(q) }
            }.value
            guard !Task.isCancelled else { return }
            self.isSearching = false
            switch outcome {
            case .success(let tracks): self.results = tracks
            case .failure(let error):
                self.results = []
                self.searchError = error.localizedDescription
            }
        }
    }

    func loadPlaylists() {
        guard !isLoadingPlaylists else { return }
        isLoadingPlaylists = true
        playlistError = nil
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try MusicBridge.playlists() }
            }.value
            guard let self else { return }
            self.isLoadingPlaylists = false
            switch outcome {
            case .success(let lists):
                self.playlists = lists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            case .failure(let error): self.playlistError = error.localizedDescription
            }
        }
    }

    func loadTracks(of playlist: PlaylistInfo) {
        selectedPlaylist = playlist
        playlistTracks = []
        playlistError = nil
        isLoadingTracks = true
        trackRevision += 1
        let revision = trackRevision
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try MusicBridge.tracks(inPlaylist: playlist.id) }
            }.value
            guard let self, self.selectedPlaylist?.id == playlist.id,
                  self.trackRevision == revision else { return }
            self.isLoadingTracks = false
            switch outcome {
            case .success(let tracks): self.playlistTracks = tracks
            case .failure(let error): self.playlistError = error.localizedDescription
            }
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
