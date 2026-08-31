import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    /// Floor for the auto-fit. A pane with two rows in it would otherwise
    /// shrink the window to a sliver — shorter than its own category sidebar.
    /// A floor never reintroduces scrolling; it only leaves slack.
    private static let minContentHeight: CGFloat = 260

    /// Pane content height the window was last sized to. Re-fitting only when
    /// this changes is what keeps us from fighting the user: dragging the
    /// window taller doesn't change a pane's intrinsic height, so we leave it
    /// alone. Switching panes does, so that resizes.
    private var lastFittedPaneHeight: CGFloat = 0

    convenience init() {
        let hosting = SettingsHostingController(rootView: SettingsView())
        let window = SettingsWindow(contentViewController: hosting)
        window.title = "Settings"
        window.setContentSize(NSSize(width: 680, height: 560))
        window.styleMask = [.titled, .closable, .resizable]
        // Height floor is deliberately low: the window sizes itself to the
        // selected pane, and General is only a couple of rows tall. (AppKit
        // manages the real limits itself once a window has a contentView-
        // Controller, so the fit below enforces `minContentHeight` directly.)
        window.contentMinSize = NSSize(width: 600, height: Self.minContentHeight)
        window.isReleasedWhenClosed = false        // reuse on next ⌘,
        window.center()
        window.setFrameAutosaveName("mTerm.SettingsWindow")
        self.init(window: window)
        window.windowController = self
        hosting.onLayout = { [weak self] in self?.fitWindowToPaneIfNeeded() }
        // Catches a font installed while Settings sat open in the background:
        // going off to install one makes another app key, and coming back
        // makes this window key again. `show()` covers the first open and the
        // case where the window is already key, which posts nothing.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { _ in FontCatalogStore.shared.refresh() }
    }

    /// Closes the Settings window if it's on screen, leaving it alone if it was
    /// never opened.
    ///
    /// Deliberately goes through `NSApp.windows` rather than `shared`, which is
    /// lazy: touching it here would build the whole SwiftUI hierarchy just to
    /// discover there was nothing to close, on every window close.
    static func closeIfOpen() {
        for window in NSApp.windows where window.windowController is SettingsWindowController {
            window.close()
        }
    }

    static func show() {
        FontCatalogStore.shared.refresh()
        shared.showWindow(nil)
        shared.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Sizes the window so the selected pane fits without scrolling, the way
    /// System Settings does. Only the height moves — the user's width stays —
    /// and growth stops at the edge of the screen, so a pane taller than the
    /// display still scrolls rather than running off it.
    private func fitWindowToPaneIfNeeded() {
        guard let window,
              let contentView = window.contentView,
              let scroll = Self.paneScrollView(in: contentView),
              let document = scroll.documentView
        else { return }

        let paneHeight = document.frame.height
        guard paneHeight > 1, abs(paneHeight - lastFittedPaneHeight) > 1 else { return }
        let isFirstFit = lastFittedPaneHeight == 0
        lastFittedPaneHeight = paneHeight

        // Anything laid out outside the scroller (inset headers and the like)
        // still needs room, so measure it rather than assuming zero.
        let chrome = max(0, contentView.frame.height - scroll.contentView.bounds.height)
        var targetContentHeight = max(paneHeight + chrome, Self.minContentHeight)

        var targetFrame = window.frameRect(forContentRect: NSRect(
            x: 0, y: 0, width: contentView.frame.width, height: targetContentHeight))
        if let screen = window.screen ?? NSScreen.main {
            let titleBar = targetFrame.height - targetContentHeight
            targetContentHeight = min(targetContentHeight, screen.visibleFrame.height - titleBar)
            targetFrame = window.frameRect(forContentRect: NSRect(
                x: 0, y: 0, width: contentView.frame.width, height: targetContentHeight))
        }

        var frame = window.frame
        guard abs(frame.height - targetFrame.height) > 1 else { return }
        // Grow downward: the title bar stays put instead of the window
        // creeping up the screen every time you switch panes...
        frame.origin.y += frame.height - targetFrame.height
        frame.size.height = targetFrame.height
        // ...unless that would push the bottom off the display, in which case
        // AppKit slides the whole window back into the visible area for us.
        frame = window.constrainFrameRect(frame, to: window.screen)

        // Out of the layout pass that triggered us — resizing re-enters layout.
        DispatchQueue.main.async {
            window.setFrame(frame, display: true,
                            animate: !isFirstFit && window.isVisible)
        }
    }

    /// The detail pane's scroll view — the widest one in the window, since the
    /// category sidebar's list is always narrower. Returns nil if SwiftUI ever
    /// stops backing a grouped `Form` with a scroll view, in which case the
    /// window simply keeps whatever size it has.
    private static func paneScrollView(in root: NSView) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found.filter { $0.frame.width > 300 }
                    .max { $0.frame.width < $1.frame.width }
    }
}

/// Hosting controller that reports every AppKit layout pass, which is how the
/// window learns that the selected pane (and so the content height) changed.
private final class SettingsHostingController: NSHostingController<SettingsView> {
    var onLayout: (() -> Void)?

    override func viewDidLayout() {
        super.viewDidLayout()
        onLayout?()
    }
}

/// NSWindow subclass that closes on Esc (and ⌘.) via the responder chain's
/// `cancelOperation(_:)` hook.
private final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}
