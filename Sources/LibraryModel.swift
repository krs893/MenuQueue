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
            // Music's own search verb only covers locally stored tracks, which
            // for an Apple Music library is a small minority. See LibraryIndex.
            var outcome = await Task.detached(priority: .userInitiated) {
                Result { try LibraryIndex.shared.search(q) }
            }.value
            // Nothing found may just mean the snapshot predates the song the
            // user has only just added. Re-read once before saying "no hits",
            // otherwise a new track stays invisible until the cache ages out.
            if case .success(let hits) = outcome, hits.isEmpty,
               !LibraryIndex.shared.isFresh(within: 10) {
                outcome = await Task.detached(priority: .userInitiated) {
                    LibraryIndex.shared.invalidate()
                    return Result { try LibraryIndex.shared.search(q) }
                }.value
            }
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

    /// Explicit refresh: drop the library snapshot as well, so newly added
    /// songs show up in search and the playlist counts are recomputed.
    func reloadEverything() {
        LibraryIndex.shared.invalidate()
        loadPlaylists()
        if let selected = selectedPlaylist { loadTracks(of: selected) }
    }

    func loadPlaylists() {
        // Pay the one-second index load in the background while the user is
        // still looking at the queue, not on their first keystroke.
        LibraryIndex.shared.warm()
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
                let counts = LibraryIndex.shared.playlistCounts()
                self.playlists = lists
                    .map { pl in
                        // Once the index is warm its counts are free and cover
                        // cloud tracks that `count of tracks` can miss.
                        guard let n = counts[pl.id], n != pl.count else { return pl }
                        var copy = pl
                        copy.count = n
                        return copy
                    }
                // Music exposes no date for a playlist, so there is no
                // "date added" to sort by. Its own order is the closest thing
                // and matches what the sidebar shows; alphabetising was ours.

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
