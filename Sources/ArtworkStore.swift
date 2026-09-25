import Foundation
import AppKit
import Combine

/// Album art for the track lists, fetched lazily and kept as thumbnails.
///
/// Two things make this affordable. Rows ask for their own art as they appear,
/// so a 271 track playlist only pays for the dozen on screen. And the cache is
/// keyed by album rather than by track, so an album's art is fetched once no
/// matter how many of its songs are listed — measured at 41 ms per fetch, and
/// a playlist of 271 songs turned out to span only 84 albums.
///
/// Music hands back full size art (1200×1200 here), which is far too much to
/// hold for every album, so what gets cached is a small bitmap.
@MainActor
final class ArtworkStore: ObservableObject {

    @Published private(set) var thumbnails: [String: NSImage] = [:]
    private var inFlight = Set<String>()
    /// Albums Music has no art for. Without this every appearance of those
    /// rows would start the same doomed fetch again.
    private var missing = Set<String>()

    /// Points; the bitmap is rendered at twice this for Retina.
    static let side: CGFloat = 36

    /// Art belongs to an album, not a track. Tracks with no album fall back to
    /// their own id so they still get a picture rather than sharing a blank key.
    nonisolated static func key(_ track: MusicTrack) -> String {
        let album = track.album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !album.isEmpty else { return "track:\(track.databaseID)" }
        return "album:\(track.artist.lowercased())\u{1}\(album.lowercased())"
    }

    func thumbnail(for track: MusicTrack) -> NSImage? {
        thumbnails[Self.key(track)]
    }

    func load(_ track: MusicTrack) async {
        let key = Self.key(track)
        guard thumbnails[key] == nil, !inFlight.contains(key), !missing.contains(key) else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        let dbID = track.databaseID
        let playlistID = track.sourcePlaylistID
        let side = Self.side
        let thumbnail = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let full = MusicBridge.artwork(databaseID: dbID, playlistID: playlistID) else { return nil }
            return ArtworkStore.downscale(full, to: side)
        }.value

        if let thumbnail {
            thumbnails[key] = thumbnail
        } else {
            missing.insert(key)
        }
    }

    /// Resamples into a small bitmap so the full size original can be released
    /// rather than retained once per album.
    nonisolated static func downscale(_ image: NSImage, to side: CGFloat) -> NSImage? {
        let pixels = Int(side * 2)
        guard pixels > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = NSSize(width: side, height: side)

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        // Square crop from the centre: covers are square, but a stray oblong
        // one should not come out stretched.
        let source = image.size
        let edge = min(source.width, source.height)
        let crop = NSRect(x: (source.width - edge) / 2, y: (source.height - edge) / 2,
                          width: edge, height: edge)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                   from: crop, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: NSSize(width: side, height: side))
        out.addRepresentation(rep)
        return out
    }
}
