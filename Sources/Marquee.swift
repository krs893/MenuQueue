import Foundation

/// A fixed-width ticker for the menu bar.
///
/// The menu bar is shared with every other status item, so the width has to be
/// a constant rather than "however long this title happens to be". Anything
/// that does not fit scrolls past a window of `width` characters instead of
/// being cut off with an ellipsis.
enum Marquee {

    /// Separates the end of the text from its repeat, so a scrolling title
    /// reads as one loop rather than running its last word into its first.
    static let gap = "   ·   "

    /// The slice visible at `step`. Steps advance one character at a time and
    /// wrap, so a caller can keep incrementing forever.
    ///
    /// Counting in characters rather than points keeps this testable and
    /// predictable; the status item itself is pinned to a fixed point width,
    /// so a proportional font cannot make the item jitter as glyphs shift.
    static func window(_ text: String, width: Int, step: Int) -> String {
        guard width > 0 else { return "" }
        let characters = Array(text)
        guard characters.count > width else { return text }

        let loop = characters + Array(gap)
        // Negative steps would otherwise index backwards out of the loop.
        let start = ((step % loop.count) + loop.count) % loop.count
        var out = String()
        out.reserveCapacity(width)
        for offset in 0..<width {
            out.append(loop[(start + offset) % loop.count])
        }
        return out
    }

    /// Whether a title is long enough to need scrolling at all. A short title
    /// must sit still: a ticker that never stops is hard to read past.
    static func scrolls(_ text: String, width: Int) -> Bool {
        width > 0 && text.count > width
    }

    /// What to show when the ticker is parked — paused playback, say. The head
    /// of the title is the useful part, so trim the tail rather than the front.
    static func parked(_ text: String, width: Int) -> String {
        guard width > 0 else { return "" }
        guard text.count > width else { return text }
        return String(text.prefix(max(width - 1, 0))) + "…"
    }
}
