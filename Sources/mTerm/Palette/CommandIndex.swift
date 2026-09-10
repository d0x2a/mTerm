import AppKit

/// One action the ⌘K hub can run, and the words that should find it.
///
/// Every entry sends a selector down the responder chain — the same selector
/// the menu item sends. The hub deliberately owns no behaviour of its own, so
/// there is never a command you can reach from ⌘K and not from the menu bar.
struct CommandEntry {
    let label: String
    /// Words that should find this and aren't in the label — the vocabulary
    /// someone arrives with rather than the one the menu happens to use.
    /// "cls" finds Clear Screen; "grep" finds Find in Scrollback.
    let keywords: String
    let shortcut: String?
    let selector: Selector

    init(_ label: String, _ shortcut: String?, _ selector: Selector, _ keywords: String = "") {
        self.label = label
        self.shortcut = shortcut
        self.selector = selector
        self.keywords = keywords
    }
}

/// Every action in the hub, in the order it should break ties.
///
/// This is a hand-written list rather than a walk of `NSApp.mainMenu`, for one
/// reason: keywords. A menu walk gives titles and key equivalents for free but
/// no vocabulary, and the vocabulary is most of what makes search feel like it
/// understands you. `missingFromIndex()` below is what keeps the two in step.
enum CommandIndex {
    static let all: [CommandEntry] = [
        // Tabs and windows — the actions that share the hub's own subject.
        .init("New Tab", "⌘T", #selector(AppDelegate.openNewTab(_:)),
              "open create shell window"),
        .init("Close Tab", "⌘W", #selector(AppDelegate.closeActiveTab(_:)),
              "quit kill end"),
        .init("Show Next Tab", "⇧⌘]", #selector(AppDelegate.selectNextTab(_:)),
              "cycle switch forward"),
        .init("Show Previous Tab", "⇧⌘[", #selector(AppDelegate.selectPreviousTab(_:)),
              "cycle switch back"),

        // Scrollback.
        .init("Find in Scrollback…", "⌘F", #selector(TerminalView.performFind(_:)),
              "search grep buffer history text"),
        .init("Find Next", "⌘G", #selector(TerminalView.findNext(_:)),
              "search again match"),
        .init("Find Previous", "⇧⌘G", #selector(TerminalView.findPrevious(_:)),
              "search back match"),
        .init("Jump to Previous Prompt", "⌘↑",
              #selector(TerminalView.jumpToPreviousPrompt(_:)),
              "osc 133 mark command back shell integration"),
        .init("Jump to Next Prompt", "⌘↓",
              #selector(TerminalView.jumpToNextPrompt(_:)),
              "osc 133 mark command forward shell integration"),
        .init("Clear Screen", "⇧⌘K", #selector(TerminalView.clearScreen(_:)),
              "clear cls wipe erase scrollback reset blank"),

        // Clipboard.
        .init("Copy", "⌘C", #selector(NSText.copy(_:)), "clipboard yank selection"),
        .init("Copy All", "⇧⌘C", #selector(TerminalView.copyAll(_:)),
              "clipboard yank buffer everything"),
        .init("Paste", "⌘V", #selector(NSText.paste(_:)), "clipboard insert"),
        .init("Select All", "⌘A", #selector(NSText.selectAll(_:)), "clipboard everything"),

        // Appearance. "Change Theme…" is handled as a drill-in stage rather
        // than a selector — see `PaletteCommand.drillIntoThemes`.
        .init("Settings…", "⌘,", #selector(AppDelegate.showSettings(_:)),
              "preferences options config"),

        // Window and app.
        .init("Enter Full Screen", "⌃⌘F", #selector(NSWindow.toggleFullScreen(_:)),
              "fullscreen maximise maximize"),
        .init("Minimize", "⌘M", #selector(NSWindow.performMiniaturize(_:)),
              "hide dock window"),
        .init("Hide mTerm", "⌘H", #selector(NSApplication.hide(_:)), "background away"),
        .init("About mTerm", nil,
              #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
              "version credits licence license"),
        .init("Quit mTerm", "⌘Q", #selector(NSApplication.terminate(_:)), "exit close app"),
    ]

    /// Actions whose selector nothing in the current responder chain answers
    /// are dropped rather than greyed out. Discovering that a command *exists*
    /// is the menu bar's job; the hub's job is speed, and a list of dead rows
    /// is just further to scroll.
    ///
    /// Called while the terminal view is still first responder — once the hub's
    /// search field takes focus the chain answers `copy:`/`paste:` itself and
    /// every clipboard action would look valid.
    static func available() -> [CommandEntry] {
        all.filter { NSApp.target(forAction: $0.selector, to: nil, from: nil) != nil }
    }

    /// Selectors reachable from the menu bar that no entry above covers.
    ///
    /// The hub is a second hand-maintained list of the app's actions, and the
    /// failure mode of a second list is silent drift: a command added to a menu
    /// and not added here is simply unfindable, with nothing to notice it. This
    /// is checked on launch in debug builds — see `AppDelegate`.
    static func missingFromIndex(menu: NSMenu) -> [String] {
        let indexed = Set(all.map { NSStringFromSelector($0.selector) })
        var missing: [String] = []

        // Actions that are deliberately menu-only: separators and container
        // items carry no selector, the standard hide/show-all items are noise
        // in a search field, and the profile and tab-number items are already
        // in the hub as generated rows rather than as fixed entries.
        let exempt: Set<String> = [
            NSStringFromSelector(#selector(AppDelegate.openNewTabWithProfile(_:))),
            NSStringFromSelector(#selector(AppDelegate.selectTabByNumber(_:))),
            NSStringFromSelector(#selector(NSApplication.hideOtherApplications(_:))),
            NSStringFromSelector(#selector(NSApplication.unhideAllApplications(_:))),
            NSStringFromSelector(#selector(NSWindow.performZoom(_:))),
            // The hub's own chord. Nothing is gained by a row that reopens
            // the list you are already looking at.
            NSStringFromSelector(#selector(AppDelegate.toggleCommandPalette(_:))),
        ]

        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { walk(submenu) }
                guard let action = item.action else { continue }
                let name = NSStringFromSelector(action)
                if !indexed.contains(name), !exempt.contains(name), !missing.contains(name) {
                    missing.append(name)
                }
            }
        }
        walk(menu)
        return missing
    }
}

// MARK: - building the hub's rows

enum PaletteIndex {
    /// Everything the hub can show, given the window it was opened from.
    ///
    /// Built once per open. A live list would be worse than stale: a background
    /// tab's prompt firing between two keystrokes would renumber the rows under
    /// a selection the user is aiming at.
    static func items(for host: MainWindowController,
                      actions: [CommandEntry]) -> [PaletteItem] {
        tabItems(host: host) + actionItems(host: host, actions: actions)
            + themeItems() + settingItems()
    }

    // MARK: tabs

    static func tabItems(host: MainWindowController) -> [PaletteItem] {
        let controllers = allControllers(preferring: host)
        let showWindowLabels = controllers.count > 1

        return controllers.flatMap { controller -> [PaletteItem] in
            controller.tabs.enumerated().map { index, tab in
                let directory = tab.terminalView.currentDirectory.map(foldHome) ?? ""
                let process = tab.terminalView.foregroundProcess?.name
                let info = PaletteTabInfo(
                    index: index + 1,
                    title: tab.displayTitle,
                    directory: directory,
                    process: process,
                    tmuxWindowID: tab.tmuxWindowID,
                    wantsAttention: tab.wantsAttention,
                    isCurrent: controller === host && tab.id == host.activeTabId,
                    windowLabel: showWindowLabels ? windowLabel(for: controller) : nil
                )
                return PaletteItem(
                    kind: .tab,
                    label: tab.displayTitle,
                    // The directory first: it's the field most queries land on,
                    // and a tab's real identity when three of them are called
                    // the same thing.
                    secondary: [directory, process ?? "", tab.tmuxWindowID.map { "tmux \($0)" } ?? ""],
                    keywords: "tab window",
                    command: .switchTab(window: controller, tabId: tab.id),
                    tab: info
                )
            }
        }
    }

    /// The hub's own window first, then the rest in window order, so the tabs
    /// you are most likely to want don't sit under another window's.
    static func allControllers(preferring host: MainWindowController) -> [MainWindowController] {
        let others = NSApp.windows
            .compactMap { $0.windowController as? MainWindowController }
            .filter { $0 !== host }
        return [host] + others
    }

    private static func windowLabel(for controller: MainWindowController) -> String {
        let active = controller.tabs.first { $0.id == controller.activeTabId }
        return active?.displayTitle ?? "Window"
    }

    // MARK: actions

    static func actionItems(host: MainWindowController,
                            actions: [CommandEntry]) -> [PaletteItem] {
        var items = actions.map {
            PaletteItem(kind: .action, label: $0.label, keywords: $0.keywords,
                        shortcut: $0.shortcut, command: .send($0.selector))
        }

        // A drill-in rather than a selector: the themes are also flattened into
        // the list below, so "solarized" finds one directly, but "theme" should
        // land somewhere that lists them all.
        items.append(PaletteItem(
            kind: .action, label: "Change Theme…",
            keywords: "colours colors palette scheme appearance dark light",
            command: .drillIntoThemes))

        if host.isTmuxActive {
            items.append(PaletteItem(
                kind: .action, label: "New tmux Window",
                keywords: "tmux multiplexer session attach control mode",
                command: .tmuxNewWindow(host)))
        }

        // Profiles are flattened rather than drilled into: there are few of
        // them, and typing the profile's own name should be enough.
        let profiles = ProfileStore.shared.profiles
        for (i, profile) in profiles.enumerated() {
            items.append(PaletteItem(
                kind: .action,
                label: "New Tab with Profile: \(profile.name)",
                secondary: [profile.name],
                keywords: "profile shell start open",
                shortcut: i < 9 ? "⌥⌘\(i + 1)" : nil,
                command: .newTabWithProfile(profile.id)))
        }
        return items
    }

    // MARK: themes

    static func themeItems(prefixed: Bool = true) -> [PaletteItem] {
        ThemeStore.shared.allThemes.map { theme in
            PaletteItem(
                kind: .theme,
                label: prefixed ? "Theme: \(theme.name)" : theme.name,
                secondary: [theme.name],
                keywords: "theme colours colors palette scheme "
                    + (theme.appearance == .dark ? "dark" : "light"),
                command: .applyTheme(theme.id),
                theme: theme)
        }
    }

    /// Applies a theme the way picking one in Settings would, and flips the
    /// appearance mode only when it has to: setting the dark theme while the
    /// app is following a light system would otherwise change nothing visible,
    /// which reads as the command having failed.
    static func applyTheme(id: String) {
        guard let theme = ThemeStore.shared.allThemes.first(where: { $0.id == id }) else { return }
        var settings = ThemeStore.shared.settings
        switch theme.appearance {
        case .light:
            settings.lightThemeId = theme.id
            if settings.appearanceMode == .dark { settings.appearanceMode = .light }
        case .dark:
            settings.darkThemeId = theme.id
            if settings.appearanceMode == .light { settings.appearanceMode = .dark }
        }
        if settings.appearanceMode == .system,
           ThemeStore.currentTheme.appearance != theme.appearance {
            settings.appearanceMode = theme.appearance == .dark ? .dark : .light
        }
        ThemeStore.shared.settings = settings
    }

    // MARK: settings

    /// The Settings index, reused whole. Its labels and keywords are already
    /// the vocabulary people search Settings with, so "blurry" reaches Stroke
    /// weight from the hub exactly as it does from the Settings search field.
    static func settingItems() -> [PaletteItem] {
        SettingsIndex.all.map { entry in
            PaletteItem(
                kind: .setting,
                label: entry.label,
                secondary: [entry.category.title],
                keywords: entry.keywords.joined(separator: " "),
                command: .openSetting(entry.field))
        }
    }

    // MARK: helpers

    static func foldHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
