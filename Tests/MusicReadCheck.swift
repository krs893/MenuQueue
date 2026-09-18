import Foundation

@main
struct MusicReadCheck {
    static func main() throws {
        guard MusicBridge.isRunning else { print("SKIP: Music is not running"); return }
        let playlists = try MusicBridge.playlists()
        print("Playlists: \(playlists.count)")
        if let sample = playlists.max(by: { $0.count < $1.count }) {
            let start = Date()
            let tracks = try MusicBridge.tracks(inPlaylist: sample.id)
            print("Largest playlist: expected \(sample.count), read \(tracks.count), \(String(format: "%.2f", Date().timeIntervalSince(start))) seconds")
            guard tracks.count == sample.count else { throw CheckError.countMismatch }
            guard tracks.allSatisfy({ $0.sourcePlaylistID == sample.id }) else { throw CheckError.sourceMissing }
            if let track = tracks.first {
                guard try MusicBridge.play(databaseID: track.databaseID, playlistID: track.sourcePlaylistID,
                                           validateOnly: true) else { throw CheckError.sourceMissing }
                print("PASS: playlist track lookup (playback command disabled)")
            }
        }
        _ = try MusicBridge.nowPlaying()
        print("PASS: live read-only Music metadata and player state")
    }
    enum CheckError: Error { case countMismatch, sourceMissing }
}
