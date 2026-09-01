import AppKit

/// An attention event raised by the child process inside a terminal.
enum TerminalAttention {
    /// Terminal bell (BEL / `\a`).
    case bell
    /// OSC 9 / OSC 777 desktop-notification escape. `title` is nil for OSC 9.
    case notification(title: String?, body: String)
}

protocol TerminalViewDelegate: AnyObject {
    func terminalView(_ view: TerminalView, didUpdate title: String, cwd: String?, foregroundProcess: String?)
    func terminalViewDidTerminate(_ view: TerminalView)
    func terminalView(_ view: TerminalView, didRequestAttention attention: TerminalAttention)
    func terminalView(_ view: TerminalView, didResizeGridTo cols: Int, rows: Int)
}

final class MainWindowController: NSWindowController, NSWindowDelegate,
                                  SidebarDelegate, TerminalViewDelegate {
    /// NSWindowController.window is `unowned(unsafe)` — without our own strong
    /// reference the window would deallocate before NSApp.windows can grab it.
    private let retainedWindow: NSWindow

    private(set) var tabs: [Tab] = []
    private(set) var activeTabId: UUID?

    private let sidebar = SidebarView()
/// One Metal surface and one Renderer for the whole window; the active
    /// tab's view is pinned inside it. See TerminalSurface — a layer per tab
    /// cost a drawable pool per tab, forever.
    private let contentContainer = TerminalSurface()
    private let splitVC = WideDividerSplitViewController()
    private let gridHUD = GridSizeHUD()
    private var gridHUDHideTimer: Timer?

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

        splitVC.splitView = ThemedSplitView()
        splitVC.splitViewItems = [sidebarItem, contentItem]
        splitVC.splitView.autosaveName = "mTerm.Sidebar"
        window.contentViewController = splitVC

        gridHUD.translatesAutoresizingMaskIntoConstraints = false
        gridHUD.isHidden = true
        contentContainer.addSubview(gridHUD)
        NSLayoutConstraint.activate([
            gridHUD.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            gridHUD.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
        ])

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
        contentContainer.subviews.forEach {
            if $0 !== gridHUD { $0.removeFromSuperview() }
        }
        guard let v = activeTerminalView else { return }
        v.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(v, positioned: .below, relativeTo: gridHUD)
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
        let caption = tab.displayTitle
        guard let cwd = tab.terminalView.currentDirectory, !cwd.isEmpty else {
            return caption
        }
        let path = foldHome(cwd)
        // Don't repeat the caption when it's just the directory name (the common
        // idle-shell case, e.g. "~/source/mTerm — mTerm").
        if caption.isEmpty || caption == basename(of: cwd) { return path }
        return "\(path) — \(caption)"
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

    func terminalView(_ view: TerminalView, didUpdate title: String, cwd: String?, foregroundProcess: String?) {
        guard let tab = tabs.first(where: { $0.terminalView === view }) else { return }
        let newDisplay: String
        if foregroundProcess != nil && !title.isEmpty {
            // A program is running and has set an OSC title (e.g. ssh showing remote host).
            newDisplay = title
        } else {
            // Idle shell: prefer the local cwd, fall back to OSC title or default.
            newDisplay = basename(of: cwd) ?? (title.isEmpty ? "mTerm" : title)
        }
        if newDisplay != tab.displayTitle {
            tab.displayTitle = newDisplay
            refreshSidebar()
        }
        if activeTabId == tab.id {
            window?.title = displayWindowTitle(for: tab)
        }
    }

    func terminalView(_ view: TerminalView, didResizeGridTo cols: Int, rows: Int) {
        guard view === activeTerminalView else { return }
        gridHUD.update(cols: cols, rows: rows)
        gridHUD.alphaValue = 1
        gridHUD.isHidden = false
        gridHUDHideTimer?.invalidate()
        gridHUDHideTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) {
            [weak self] _ in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                self.gridHUD.animator().alphaValue = 0
            } completionHandler: {
                self.gridHUD.isHidden = true
            }
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

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Settings isn't a document window — with the last terminal gone there
        // is nothing left for it to configure, and leaving it up keeps the app
        // running: `applicationShouldTerminateAfterLastWindowClosed` only fires
        // once *every* window has closed, Settings included.
        //
        // The closing window is still in `NSApp.windows` at this point, so it
        // has to be excluded by identity rather than counted.
        let anotherTerminalRemains = NSApp.windows.contains {
            $0 !== window && $0.windowController is MainWindowController
        }
        if !anotherTerminalRemains {
            SettingsWindowController.closeIfOpen()
        }
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
        alert.appendKeyEquivalentHints()
        alert.enableButtonKeyboardNavigation()
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
        alert.appendKeyEquivalentHints()
        alert.enableButtonKeyboardNavigation()
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

/// Split view controller that enlarges the grab area around the thin divider.
/// The drawn divider is only 1pt and nearly blends into the terminal, which
/// makes the resize handle very hard to land on. We keep the look but widen the
/// region that initiates a drag to a comfortable target on either side.
/// The "86 × 47" readout shown while a resize is in flight. Sized to the text
/// and centered over the terminal; never takes a click or changes the cursor.
private final class GridSizeHUD: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 10
        backdrop.layer?.masksToBounds = true
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        // Monospaced digits so the box doesn't twitch as the numbers change.
        label.font = .monospacedDigitSystemFont(ofSize: 20, weight: .medium)
        label.alignment = .center
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalTo: label.widthAnchor, constant: 30),
            heightAnchor.constraint(equalTo: label.heightAnchor, constant: 18),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(cols: Int, rows: Int) {
        label.stringValue = "\(cols) × \(rows)"
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class WideDividerSplitViewController: NSSplitViewController {
    override func splitView(_ splitView: NSSplitView,
                            effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect,
                            ofDividerAt dividerIndex: Int) -> NSRect {
        let margin = ThemedSplitView.grabMargin
        var rect = proposedEffectiveRect
        rect.origin.x -= margin
        rect.size.width += margin * 2
        return rect
    }
}

/// Split view whose divider tracks the active theme. The system separator
/// reads as too bright over a dark terminal, so we derive the divider from
/// the theme background and keep it nearly blended on dark themes.
private final class ThemedSplitView: NSSplitView {
    /// Half-width (in points) of the grab/cursor zone on each side of the drawn
    /// divider. Shared with the controller's `effectiveRect` so the region that
    /// initiates a drag, the region that routes clicks here, and the region that
    /// shows the resize cursor all agree.
    static let grabMargin: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isVertical = true       // side-by-side panes (a vertical divider line)
        dividerStyle = .thin    // NSSplitViewController's default; plain NSSplitView is .thick
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: .mTermThemeDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeDidChange() {
        needsDisplay = true
        // Mark the divider strip itself dirty — invalidating the whole view
        // doesn't reliably repaint the divider region on its own.
        setNeedsDisplay(dividerRect)
    }

    /// The 1pt vertical strip between the two panes.
    private var dividerRect: NSRect {
        guard let first = arrangedSubviews.first else { return bounds }
        return NSRect(x: first.frame.maxX, y: 0,
                      width: dividerThickness, height: bounds.height)
    }

    /// The widened interaction zone centered on the drawn divider.
    private var grabRect: NSRect {
        let d = dividerRect
        return NSRect(x: d.midX - Self.grabMargin, y: 0,
                      width: Self.grabMargin * 2, height: bounds.height)
    }

    /// Claim clicks landing in the grab zone so the split view (not the flush
    /// sidebar/terminal subview underneath) receives the mouseDown and starts
    /// its native divider drag. Without this, the enlarged `effectiveRect` is
    /// moot — the subviews swallow the event before the divider ever sees it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if grabRect.contains(local) { return self }
        return super.hitTest(point)
    }

    /// Show the left/right resize cursor across the whole grab zone, not just
    /// the 1pt drawn line.
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(grabRect, cursor: .resizeLeftRight)
    }

    override func drawDivider(in rect: NSRect) {
        themedDividerColor.setFill()
        rect.fill()
    }

    private var themedDividerColor: NSColor {
        let theme = ThemeStore.currentTheme
        let bg = theme.background
        // Dark themes blend almost fully into the background; light themes get
        // a slightly stronger line so the divider stays perceptible.
        let isDark = theme.appearance == .dark
        let amount: Float = isDark ? 0.05 : 0.06
        let target: Float = isDark ? 1.0 : 0.0
        func mix(_ c: Float) -> CGFloat { CGFloat(c + (target - c) * amount) }
        return NSColor(srgbRed: mix(bg.x), green: mix(bg.y), blue: mix(bg.z),
                       alpha: CGFloat(bg.w))
    }
}
