import Foundation

/// Screen coordinates may be negative (a display to the left or below the main
/// display). Clamp exclusively to the screen containing the actual click.
enum PanelPlacement {
    /// Tall enough for the controls plus a handful of list rows, and no
    /// taller: the panel drops from the menu bar, so every extra point runs
    /// down the screen. Override with
    /// `defaults write jp.local.menuqueue panelHeight -int 560`.
    static var preferredSize: CGSize {
        let configured = UserDefaults.standard.integer(forKey: "panelHeight")
        let height = configured > 0 ? min(max(configured, 260), 900) : 470
        return CGSize(width: 400, height: CGFloat(height))
    }

    static func frame(click: CGPoint, button: CGRect?, screen: CGRect,
                      visible: CGRect, preferred: CGSize? = nil) -> CGRect {
        let preferred = preferred ?? preferredSize
        let margin: CGFloat = 8
        let width = min(preferred.width, max(1, visible.width - margin * 2))
        let height = min(preferred.height, max(1, visible.height - margin * 2))
        // Replicated macOS status items can report a frame from another screen.
        // Ignore that frame instead of letting it pull the panel to that display.
        let anchor = button.flatMap { rect -> CGRect? in
            screen.contains(CGPoint(x: rect.midX, y: rect.midY)) &&
            rect.insetBy(dx: -8, dy: -8).contains(click) ? rect : nil
        }
        let centerX = anchor?.midX ?? click.x
        let top = min(visible.maxY, anchor?.minY ?? click.y - 12) - margin
        let x = min(max(centerX - width / 2, visible.minX + margin), visible.maxX - width - margin)
        let y = min(max(top - height, visible.minY + margin), visible.maxY - height - margin)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
