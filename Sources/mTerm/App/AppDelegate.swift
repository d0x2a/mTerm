import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appearanceObservation: NSKeyValueObservation?
    /// Strong reference to the initial window's controller. NSWindow's
    /// `windowController` is weak, so without this the controller would
    /// deallocate as soon as `applicationDidFinishLaunching` returns.
    private var initialController: MainWindowController?
    private var tabCycleMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppIcon.make()

        // Must run before any tab is spawned so child shells inherit ZDOTDIR.
        ShellIntegration.install()

        // Force ThemeStore to spin up on the main thread before any session.
        _ = ThemeStore.shared

        // Wire up notifications (delegate + permission prompt). No-ops in
        // `swift run` dev builds that lack a bundle identifier.
        NotificationManager.shared.configure()

        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { app, _ in
            let isDark = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            DispatchQueue.main.async {
                ThemeStore.shared.systemAppearanceChanged(isDark: isDark)
            }
        }

        NSApp.mainMenu = MainMenu.build()
        installTabCycleShortcut()

        let controller = MainWindowController()
        initialController = controller

        let saved = Persistence.load()
        if let window = controller.window, let rect = saved?.windowFrame {
            window.setFrame(NSRect(x: rect.x, y: rect.y,
                                   width: rect.width, height: rect.height),
                            display: false)
        } else {
            controller.window?.center()
        }

        controller.showWindow(nil)

        if let saved, saved.isFullScreen,
           let window = controller.window,
           !window.styleMask.contains(.fullScreen) {
            DispatchQueue.main.async {
                window.toggleFullScreen(nil)
            }
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        let controller = activeController()
        let tabs = controller?.tabs.map { tab -> SavedTab in
            SavedTab(cwd: tab.terminalView.currentDirectory)
        } ?? []
        let window = controller?.window
        let fullScreen = window?.styleMask.contains(.fullScreen) ?? false
        // Don't persist the frame if we're in full-screen — NSWindow.frame in
        // that state is the full-screen frame, not the windowed one, and
        // we'd lock the next launch into a "windowed at full-screen size"
        // until the user resizes manually.
        let savedFrame: SavedRect? = (window.map { !fullScreen ? $0.frame : nil } ?? nil)
            .map { SavedRect(x: $0.minX, y: $0.minY,
                             width: $0.width, height: $0.height) }
        Persistence.save(SavedState(tabs: tabs,
                                    isFullScreen: fullScreen,
                                    windowFrame: savedFrame))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ThemeStore.shared.settings.warnOnCloseWithRunningProcess else {
            return .terminateNow
        }
        let controllers = NSApp.windows.compactMap { $0.windowController as? MainWindowController }
        let running = controllers.flatMap { $0.runningProcessNames() }
        guard !running.isEmpty else { return .terminateNow }

        // Anchor the sheet on the key window if it's one of ours; otherwise
        // fall back to a free-floating modal.
        let host = (NSApp.keyWindow?.windowController as? MainWindowController)?.window
            ?? controllers.first?.window

        let alert = NSAlert()
        alert.alertStyle = .warning
        if running.count == 1 {
            alert.messageText = "Quit mTerm while “\(running[0])” is running?"
        } else {
            alert.messageText = "Quit mTerm while \(running.count) processes are running?"
        }
        alert.informativeText = formatRunningList(running)
            + (running.count == 1 ? "\nIt will be terminated." : "\nThey will be terminated.")
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\u{1b}"

        if let host {
            alert.beginSheetModal(for: host) { response in
                NSApp.reply(toApplicationShouldTerminate: response == .alertFirstButtonReturn)
            }
            return .terminateLater
        }
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    private func formatRunningList(_ names: [String]) -> String {
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        return unique.joined(separator: ", ")
    }

    // MARK: settings

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.show()
    }

    // MARK: tab actions (routed to the active MainWindowController)

    @objc func openNewTab(_ sender: Any?) {
        guard let controller = activeController() else { return }
        // New tabs always start in the user's home directory.
        // Tab.init resolves nil to NSHomeDirectory().
        controller.newTab(initialCwd: nil)
    }

    @objc func closeActiveTab(_ sender: Any?) {
        activeController()?.closeActiveTab()
    }

    @objc func selectNextTab(_ sender: Any?) {
        activeController()?.selectNextTab()
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        activeController()?.selectPreviousTab()
    }

    @objc func selectTabByNumber(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        activeController()?.selectTabByNumber(item.tag)
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let controller = activeController()
        switch menuItem.action {
        case #selector(closeActiveTab(_:)):
            return (controller?.tabCount ?? 0) > 0
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)):
            return (controller?.tabCount ?? 0) > 1
        case #selector(selectTabByNumber(_:)):
            let count = controller?.tabCount ?? 0
            let n = menuItem.tag
            if n == 9 { return count > 0 }
            return n <= count
        default:
            return true
        }
    }

    // MARK: keyboard shortcuts handled outside the menu

    /// Installs a local key monitor for shortcuts that can't live on the menu:
    ///   - ⌘` / ⌘⇧`  : next / previous tab. macOS reserves ⌘` for "Move focus
    ///     to next window of the application," which would intercept a menu
    ///     binding before it could fire. The monitor pre-empts that.
    ///   - ⌘N        : new tab. Routed here (rather than added as a second
    ///     visible menu item next to ⌘T) so the File menu stays uncluttered.
    ///
    /// Match by keyCode so shift-modified presses (which change
    /// `charactersIgnoringModifiers`) still route correctly.
    private func installTabCycleShortcut() {
        tabCycleMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch (mods, event.keyCode) {
            case (.command, 0x32):                          // ⌘`
                self.selectNextTab(nil); return nil
            case ([.command, .shift], 0x32):                // ⌘⇧`
                self.selectPreviousTab(nil); return nil
            case (.command, 0x2D):                          // ⌘N
                self.openNewTab(nil); return nil
            default:
                return event
            }
        }
    }

    // MARK: helpers

    private func activeController() -> MainWindowController? {
        if let c = NSApp.keyWindow?.windowController as? MainWindowController { return c }
        if let c = NSApp.mainWindow?.windowController as? MainWindowController { return c }
        return initialController
    }
}
