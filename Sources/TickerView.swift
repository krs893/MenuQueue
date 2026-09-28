import AppKit
import QuartzCore

/// Smooth scrolling for a title that does not fit the menu bar.
///
/// The first version stepped a whole character every 0.28 s, which with
/// full-width Japanese glyphs is a 12 pt jump each time — it read as a stutter,
/// not a scroll. Here the title is rendered once into a strip (title, gap,
/// title) and Core Animation slides the strip by fractions of a point, so the
/// motion is continuous and the work happens in the render server rather than
/// on a timer in this process.
///
/// Each loop pauses on the start of the title so it can actually be read, and
/// ends where the second copy begins — identical to the first frame — so the
/// wrap is invisible.
@MainActor
final class TickerView: NSView {

    /// Points per second. Slow enough to read while it moves.
    static let speed: CGFloat = 28
    /// How long the start of the title rests before each pass.
    static let hold: CFTimeInterval = 1.2
    /// Width of the soft fade at each edge.
    static let fade: (leading: CGFloat, trailing: CGFloat) = (3, 10)

    private let strip = CALayer()
    private let edgeMask = CAGradientLayer()
    private var text = ""
    private var font = NSFont.systemFont(ofSize: 12)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        strip.anchorPoint = .zero
        layer?.addSublayer(strip)
        edgeMask.startPoint = CGPoint(x: 0, y: 0.5)
        edgeMask.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.mask = edgeMask
    }

    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    /// Clicks belong to the status item button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ text: String, font: NSFont) {
        self.text = text
        self.font = font
        render()
    }

    func stop() {
        strip.removeAllAnimations()
        strip.contents = nil
        text = ""
    }

    private var renderedHeight: CGFloat = 0

    override func layout() {
        super.layout()
        updateMask()
        if bounds.height != renderedHeight, !text.isEmpty { render() }
    }

    // The menu bar changes between light and dark with the wallpaper; the
    // rendered strip has the colour baked in, so draw it again.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        render()
    }

    // Moving to a display with a different scale needs a sharper strip.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        render()
    }

    private func updateMask() {
        let w = max(bounds.width, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeMask.frame = bounds
        edgeMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor,
                           NSColor.black.cgColor, NSColor.clear.cgColor]
        edgeMask.locations = [0, NSNumber(value: Double(Self.fade.leading / w)),
                              NSNumber(value: Double(1 - Self.fade.trailing / w)), 1]
        CATransaction.commit()
    }

    private func render() {
        guard !text.isEmpty, bounds.height > 0 else { strip.contents = nil; return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let title = NSAttributedString(string: text, attributes: attributes)
        let gap = NSAttributedString(string: Marquee.gap, attributes: attributes)
        let titleWidth = ceil(title.size().width)
        let gapWidth = ceil(gap.size().width)
        let height = bounds.height
        renderedHeight = height
        let stripWidth = titleWidth * 2 + gapWidth

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(ceil(stripWidth * scale)),
                                         pixelsHigh: Int(ceil(height * scale)),
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return }
        rep.size = NSSize(width: stripWidth, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // Resolve labelColor against the menu bar's own appearance, not the
        // app's, or the text comes out dark on a dark bar.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let y = floor((height - title.size().height) / 2)
            title.draw(at: NSPoint(x: 0, y: y))
            gap.draw(at: NSPoint(x: titleWidth, y: y))
            title.draw(at: NSPoint(x: titleWidth + gapWidth, y: y))
        }
        NSGraphicsContext.restoreGraphicsState()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.contentsScale = scale
        strip.contents = rep.cgImage
        strip.frame = CGRect(x: 0, y: 0, width: stripWidth, height: height)
        CATransaction.commit()
        updateMask()
        animate(distance: titleWidth + gapWidth)
    }

    private func animate(distance: CGFloat) {
        strip.removeAllAnimations()
        guard distance > 0 else { return }
        let travel = CFTimeInterval(distance / Self.speed)
        let total = Self.hold + travel
        let pass = CAKeyframeAnimation(keyPath: "transform.translation.x")
        // Rest on the title, slide one full title-plus-gap to the left, and
        // land on the second copy — which looks exactly like the start.
        pass.values = [0, 0, -distance]
        pass.keyTimes = [0, NSNumber(value: Self.hold / total), 1]
        pass.calculationMode = .linear
        pass.duration = total
        pass.repeatCount = .infinity
        pass.isRemovedOnCompletion = false
        strip.add(pass, forKey: "ticker")
    }
}
