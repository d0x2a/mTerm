import AppKit

/// The overlay scroll indicator's view. It exists to be looked at: every hit
/// test misses it, so a click or a selection drag that starts on top of it
/// still lands on the terminal underneath.
final class ScrollIndicatorView: NSView {
    static let width: CGFloat = 5
    static let inset: CGFloat = 3
    static let minHeight: CGFloat = 24

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    /// Where the thumb sits for a given scroll position, in the flipped
    /// coordinates of the terminal view, or nil when there is no history to
    /// indicate. The thumb covers the fraction of the buffer that is on screen
    /// and travels from the bottom (live output) to the top (as far back as the
    /// buffer goes).
    ///
    /// Kept free of view state so the geometry can be checked on its own.
    static func thumbFrame(in bounds: CGRect,
                           scrollOffset: Int,
                           scrollbackLines: Int,
                           viewportRows: Int) -> CGRect? {
        let total = scrollbackLines + viewportRows
        guard scrollbackLines > 0, viewportRows > 0, total > 0,
              bounds.height > 0, bounds.width > 0 else { return nil }

        let travel = bounds.height
        let thumb = min(travel,
                        max(minHeight, travel * CGFloat(viewportRows) / CGFloat(total)))
        // 0 = pinned to the live end, 1 = as far back as the buffer goes. The
        // view is flipped, so y grows downward and backness 1 means y = 0.
        let backness = min(1, max(0, CGFloat(scrollOffset) / CGFloat(scrollbackLines)))
        return CGRect(x: bounds.width - width - inset,
                      y: (1 - backness) * (travel - thumb),
                      width: width,
                      height: thumb)
    }
}
