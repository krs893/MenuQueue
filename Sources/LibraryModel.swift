import Foundation
import Combine

@MainActor
final class LibraryModel: ObservableObject {
    @Published var playlists: [PlaylistInfo] = []
    @Published var selectedPlaylist: PlaylistInfo?
    @Published var playlistTracks: [MusicTrack] = []
    @Published var isLoadingPlaylists = false
    @Published var isLoadingTracks = false
    @Published var playlistError: String?
    private var trackRevision = 0

    /// Explicit refresh: re-read the playlists and, if one is open, its tracks.
    func reloadEverything() {
        loadPlaylists()
        if let selected = selectedPlaylist { loadTracks(of: selected) }
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
                self.playlists = lists
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
