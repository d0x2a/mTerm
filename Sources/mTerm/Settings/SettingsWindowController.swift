import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    convenience init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = SettingsWindow(contentViewController: hosting)
        window.title = "Settings"
        window.setContentSize(NSSize(width: 680, height: 560))
        window.styleMask = [.titled, .closable, .resizable]
        window.minSize = NSSize(width: 600, height: 420)
        window.isReleasedWhenClosed = false        // reuse on next ⌘,
        window.center()
        window.setFrameAutosaveName("mTerm.SettingsWindow")
        self.init(window: window)
        window.windowController = self
    }

    static func show() {
        shared.showWindow(nil)
        shared.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// NSWindow subclass that closes on Esc (and ⌘.) via the responder chain's
/// `cancelOperation(_:)` hook.
private final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}
