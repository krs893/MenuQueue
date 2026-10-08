import Foundation
import Combine

@MainActor
final class LibraryModel: ObservableObject {
    @Published var playlists: [PlaylistInfo] = []
    /// Folders the user has drilled into, outermost first. Music lets
    /// playlists be nested, so browsing has to be a walk, not a flat list.
    @Published private(set) var folderPath: [PlaylistInfo] = []

    var currentFolder: PlaylistInfo? { folderPath.last }

    /// What belongs at the current level: folders first, then playlists, each
    /// keeping the order Music gave them.
    var visibleEntries: [PlaylistInfo] {
        let parent = currentFolder?.id
        let here = playlists.filter { $0.parentID == parent }
        return here.filter(\.isFolder) + here.filter { !$0.isFolder }
    }

    func childCount(of folder: PlaylistInfo) -> Int {
        playlists.filter { $0.parentID == folder.id }.count
    }

    /// A folder that has been deleted or renamed away must not leave the panel
    /// showing an empty level with no way out.
    func reconcileFolderPath() {
        let known = Set(playlists.map(\.id))
        if let cut = folderPath.firstIndex(where: { !known.contains($0.id) }) {
            folderPath.removeSubrange(cut...)
        }
    }

    func enter(_ folder: PlaylistInfo) {
        guard folder.isFolder else { return }
        folderPath.append(folder)
    }

    /// One step back: out of an open playlist first, then up a folder.
    /// Returns false when there is nowhere left to go.
    @discardableResult
    func goBack() -> Bool {
        if selectedPlaylist != nil { selectedPlaylist = nil; playlistTracks = []; return true }
        if !folderPath.isEmpty { folderPath.removeLast(); return true }
        return false
    }

    var canGoBack: Bool { selectedPlaylist != nil || !folderPath.isEmpty }
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

    @Published private(set) var isPreparingShuffle = false

    /// Walk descendants once, including nested folders but excluding siblings.
    func playbackPlaylists(in entry: PlaylistInfo) -> [PlaylistInfo] {
        var visited = Set<String>()
        func walk(_ item: PlaylistInfo) -> [PlaylistInfo] {
            guard visited.insert(item.id).inserted else { return [] }
            if !item.isFolder { return [item] }
            return playlists.filter { $0.parentID == item.id }.flatMap { walk($0) }
        }
        return walk(entry)
    }

    func shufflePlay(_ entry: PlaylistInfo, player: PlayerController) async {
        guard !isPreparingShuffle else { return }
        isPreparingShuffle = true
        playlistError = nil
        defer { isPreparingShuffle = false }
        let sources = playbackPlaylists(in: entry)
        let outcome = await Task.detached(priority: .userInitiated) {
            Result { () throws -> [MusicTrack] in
                var tracks: [MusicTrack] = []
                var seen = Set<Int>()
                for source in sources {
                    for var track in try MusicBridge.tracks(inPlaylist: source.id) {
                        track.sourcePlaylistID = source.id
                        // A song present in several child playlists plays only once.
                        if !entry.isFolder || seen.insert(track.databaseID).inserted {
                            tracks.append(track)
                        }
                    }
                }
                return tracks
            }
        }.value
        switch outcome {
        case .success(let tracks):
            guard !tracks.isEmpty else {
                playlistError = "シャッフル再生できる曲がありません"
                return
            }
            await player.shuffleNatively(playlistIDs: sources.map(\.id), fallback: tracks)
        case .failure(let error):
            playlistError = error.localizedDescription
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
                // The working playlist is an implementation detail; listing it
                // would offer "MenuQueue" as if it were one of the user's own.
                let working = MusicBridge.workingPlaylistID
                self.playlists = lists.filter { $0.id != working }
                self.reconcileFolderPath()
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
