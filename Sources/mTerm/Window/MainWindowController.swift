import AppKit

/// An attention event raised by the child process inside a terminal.
enum TerminalAttention {
    /// Terminal bell (BEL / `\a`).
    case bell
    /// OSC 9 / OSC 777 desktop-notification escape. `title` is nil for OSC 9.
    case notification(title: String?, body: String)
}

protocol TerminalViewDelegate: AnyObject {
    func terminalView(_ view: TerminalView, didUpdate title: String, cwd: String?)
    func terminalViewDidTerminate(_ view: TerminalView)
    func terminalView(_ view: TerminalView, didRequestAttention attention: TerminalAttention)
}

final class MainWindowController: NSWindowController, NSWindowDelegate,
                                  SidebarDelegate, TerminalViewDelegate {
    /// NSWindowController.window is `unowned(unsafe)` — without our own strong
    /// reference the window would deallocate before NSApp.windows can grab it.
    private let retainedWindow: NSWindow

    private(set) var tabs: [Tab] = []
    private(set) var activeTabId: UUID?

    private let sidebar = SidebarView()
    private let contentContainer = NSView()
    private let splitVC = NSSplitViewController()

    init(initialCwd: String? = nil) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "mTerm"
        window.minSize = NSSize(width: 600, height: 320)
        window.center()
        self.retainedWindow = window
        super.init(window: window)
        window.delegate = self
        // Frame is restored explicitly from Persistence in AppDelegate; the
        // built-in autosave only captured the user (non-zoomed) frame which
        // led to surprising behavior when the user double-clicked to zoom.

        sidebar.delegate = self

        let sidebarVC = NSViewController()
        sidebarVC.view = sidebar
        // Use a plain split item (not `sidebarWithViewController:`), which
        // would apply the system vibrancy / "floating sidebar" appearance.
        let sidebarItem = NSSplitViewItem(viewController: sidebarVC)
        sidebarItem.minimumThickness = 140
        sidebarItem.maximumThickness = 320
        sidebarItem.preferredThicknessFraction = 0.18
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = .defaultLow + 1

        let contentVC = NSViewController()
        contentVC.view = contentContainer
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        let contentItem = NSSplitViewItem(viewController: contentVC)

        splitVC.splitViewItems = [sidebarItem, contentItem]
        splitVC.splitView.autosaveName = "mTerm.Sidebar"
        window.contentViewController = splitVC

        newTab(initialCwd: initialCwd)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: tab actions

    @discardableResult
    func newTab(initialCwd: String? = nil) -> Tab {
        let tab = Tab(initialCwd: initialCwd)
        tab.terminalView.delegate = self
        tabs.append(tab)
        selectTab(tab.id)
        return tab
    }

    func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabId = id
        installActiveTerminalView()
        refreshSidebar()
        if let tab = tabs.first(where: { $0.id == id }) {
            window?.title = displayWindowTitle(for: tab)
        }
    }

    func closeTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if ThemeStore.shared.settings.warnOnCloseWithRunningProcess,
           let process = tab.terminalView.foregroundProcess {
            confirmCloseTab(named: process.name) { [weak self] confirmed in
                if confirmed { self?.forceCloseTab(id) }
            }
            return
        }
        forceCloseTab(id)
    }

    /// Closes a tab without asking. Used by `closeTab` after confirmation,
    /// and by `terminalViewDidTerminate` where the shell has already exited
    /// (and the foreground-process check would be moot).
    private func forceCloseTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let removed = tabs.remove(at: idx)
        removed.terminalView.delegate = nil
        if removed.terminalView.superview != nil {
            removed.terminalView.removeFromSuperview()
        }
        if tabs.isEmpty {
            window?.close()
            return
        }
        if activeTabId == id {
            let nextIdx = min(idx, tabs.count - 1)
            selectTab(tabs[nextIdx].id)
        } else {
            refreshSidebar()
        }
    }

    /// Names of foreground processes across all tabs in this window.
    /// Used by AppDelegate to aggregate across windows for the quit prompt
    /// and by `windowShouldClose` for the window-close prompt.
    func runningProcessNames() -> [String] {
        tabs.compactMap { $0.terminalView.foregroundProcess?.name }
    }

    // MARK: keyboard / menu shortcuts

    var activeTerminalView: TerminalView? {
        tabs.first(where: { $0.id == activeTabId })?.terminalView
    }

    var tabCount: Int { tabs.count }

    func closeActiveTab() {
        if let id = activeTabId { closeTab(id) }
    }

    func selectNextTab() {
        guard let activeTabId,
              let idx = tabs.firstIndex(where: { $0.id == activeTabId }),
              tabs.count > 1
        else { return }
        let next = (idx + 1) % tabs.count
        selectTab(tabs[next].id)
    }

    func selectPreviousTab() {
        guard let activeTabId,
              let idx = tabs.firstIndex(where: { $0.id == activeTabId }),
              tabs.count > 1
        else { return }
        let prev = (idx - 1 + tabs.count) % tabs.count
        selectTab(tabs[prev].id)
    }

    /// 1-8 select by index; 9 selects the last tab (Chrome/Safari convention).
    func selectTabByNumber(_ n: Int) {
        guard !tabs.isEmpty else { return }
        if n == 9 {
            selectTab(tabs.last!.id)
            return
        }
        let idx = n - 1
        if idx >= 0 && idx < tabs.count {
            selectTab(tabs[idx].id)
        }
    }

    // MARK: internals

    private func installActiveTerminalView() {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let v = activeTerminalView else { return }
        v.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            v.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            v.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        window?.makeFirstResponder(v)
    }

    private func refreshSidebar() {
        sidebar.update(
            tabs: tabs.map { ($0.id, $0.displayTitle) },
            activeId: activeTabId
        )
    }

    // MARK: title helpers

    private func displayWindowTitle(for tab: Tab) -> String {
        if let cwd = tab.terminalView.currentDirectory, !cwd.isEmpty {
            return foldHome(cwd)
        }
        return tab.displayTitle
    }

    private func foldHome(_ cwd: String) -> String {
        let home = NSHomeDirectory()
        if cwd == home { return "~" }
        if cwd.hasPrefix(home + "/") { return "~" + cwd.dropFirst(home.count) }
        return cwd
    }

    private func basename(of cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        if cwd == "/" { return "/" }
        if cwd == NSHomeDirectory() { return "~" }
        return (cwd as NSString).lastPathComponent
    }

    // MARK: SidebarDelegate

    func sidebarDidSelect(tabId: UUID)      { selectTab(tabId) }
    func sidebarDidRequestClose(tabId: UUID) { closeTab(tabId) }

    /// SidebarView reports `toIndex` as a gap index in the pre-move array.
    /// We remove the dragged tab first and then insert at the target gap,
    /// adjusting by -1 when the gap was to the right of the original slot
    /// (the removal shifted later indices down by one).
    func sidebarDidReorderTab(tabId: UUID, toIndex: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = tabs.remove(at: from)
        let insertAt = toIndex > from ? toIndex - 1 : toIndex
        let clamped = max(0, min(tabs.count, insertAt))
        tabs.insert(tab, at: clamped)
        refreshSidebar()
    }

    // MARK: TerminalViewDelegate

    func terminalView(_ view: TerminalView, didUpdate title: String, cwd: String?) {
        guard let tab = tabs.first(where: { $0.terminalView === view }) else { return }
        let newDisplay = basename(of: cwd) ?? (title.isEmpty ? "mTerm" : title)
        if newDisplay != tab.displayTitle {
            tab.displayTitle = newDisplay
            refreshSidebar()
        }
        if activeTabId == tab.id {
            window?.title = displayWindowTitle(for: tab)
        }
    }

    func terminalViewDidTerminate(_ view: TerminalView) {
        guard let tab = tabs.first(where: { $0.terminalView === view }) else { return }
        forceCloseTab(tab.id)
    }

    func terminalView(_ view: TerminalView, didRequestAttention attention: TerminalAttention) {
        let settings = ThemeStore.shared.settings
        guard settings.notificationsEnabled else { return }
        guard let tab = tabs.first(where: { $0.terminalView === view }) else { return }

        // The bell is the noisy one (readline rings it on completion failures
        // too), so it has its own opt-out. OSC notifications are explicit
        // requests from the program, so they always go through.
        if case .bell = attention, !settings.notifyOnBell { return }

        // Don't interrupt the user with what they're already looking at.
        if settings.notifyOnlyWhenUnfocused && isTabFrontmost(tab) { return }

        let process = tab.terminalView.foregroundProcess?.name
        let title: String
        let body: String
        switch attention {
        case .bell:
            title = process ?? tab.displayTitle
            body = "wants your attention"
        case .notification(let t, let b):
            title = t ?? process ?? tab.displayTitle
            body = b
        }

        NotificationManager.shared.post(title: title, body: body, tabId: tab.id)
    }

    /// True when this tab is the one the user is actively looking at: app
    /// frontmost, this window key, and this the selected tab.
    private func isTabFrontmost(_ tab: Tab) -> Bool {
        NSApp.isActive
            && (window?.isKeyWindow ?? false)
            && activeTabId == tab.id
    }

    // MARK: NSWindowDelegate close confirmation

    /// Set by `windowShouldClose` so the post-confirmation close goes through
    /// without re-prompting.
    private var bypassWindowCloseConfirmation = false

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if bypassWindowCloseConfirmation { return true }
        guard ThemeStore.shared.settings.warnOnCloseWithRunningProcess else { return true }
        let running = runningProcessNames()
        guard !running.isEmpty else { return true }

        confirmCloseWindow(running: running) { [weak self] confirmed in
            guard let self, confirmed else { return }
            self.bypassWindowCloseConfirmation = true
            self.window?.close()
        }
        return false
    }

    // MARK: confirmation alerts

    private func confirmCloseTab(named name: String, then: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close tab while “\(name)” is running?"
        alert.informativeText = "The running process will be terminated."
        alert.addButton(withTitle: "Close Tab")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\u{1b}" // Escape
        guard let window else {
            then(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        alert.beginSheetModal(for: window) { response in
            then(response == .alertFirstButtonReturn)
        }
    }

    private func confirmCloseWindow(running: [String], then: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if running.count == 1 {
            alert.messageText = "Close window while “\(running[0])” is running?"
        } else {
            alert.messageText = "Close window while \(running.count) processes are running?"
        }
        alert.informativeText = formatRunningList(running)
            + (running.count == 1 ? "\nIt will be terminated." : "\nThey will be terminated.")
        alert.addButton(withTitle: "Close Window")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        guard let window else {
            then(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        alert.beginSheetModal(for: window) { response in
            then(response == .alertFirstButtonReturn)
        }
    }

    private func formatRunningList(_ names: [String]) -> String {
        // Deduplicate while preserving order so "ssh, ssh, vim" → "ssh, vim".
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        return unique.joined(separator: ", ")
    }
}
