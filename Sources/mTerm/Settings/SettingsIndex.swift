import Foundation

/// The panes, in sidebar order.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance, profiles, triggers, general, notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance:    return "Appearance"
        case .profiles:      return "Profiles"
        case .triggers:      return "Triggers"
        case .general:       return "General"
        case .notifications: return "Notifications"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance:    return "paintbrush"
        case .profiles:      return "person.crop.rectangle.stack"
        case .triggers:      return "bolt.horizontal"
        case .general:       return "gearshape"
        case .notifications: return "bell"
        }
    }
}

/// One searchable control.
struct SettingsEntry: Identifiable, Hashable {
    let field: SettingsField
    let category: SettingsCategory
    /// What the control is called in its pane, near enough to recognise the
    /// row you land on.
    let label: String
    /// Words that should find this and aren't in the label — the vocabulary
    /// someone arrives with rather than the one the pane happens to use.
    /// "antialiasing" finds stroke weight; "history" finds scrollback.
    let keywords: [String]

    var id: SettingsField { field }

    init(_ field: SettingsField, _ category: SettingsCategory,
         _ label: String, _ keywords: String = "") {
        self.field = field
        self.category = category
        self.label = label
        self.keywords = keywords.split(separator: " ").map(String.init)
    }
}

/// Every control in Settings, in the order its pane lays them out.
///
/// This is also where the Tab order comes from — `fields(in:)` below — so
/// there is one list rather than two that can disagree. A control added to a
/// pane and not added here is both unfindable by search and unreachable by
/// Tab, which is a great deal more noticeable than being merely unsearchable.
enum SettingsIndex {
    static let all: [SettingsEntry] = [
        // Appearance
        .init(.mode, .appearance, "Mode",
              "light dark system theme appearance follow auto"),
        .init(.lightTheme, .appearance, "Light theme",
              "colours colors palette scheme solarized nord dracula gruvbox"),
        .init(.darkTheme, .appearance, "Dark theme",
              "colours colors palette scheme solarized nord dracula gruvbox"),
        .init(.importTheme, .appearance, "Import theme",
              "itermcolors iterm2 load file custom"),
        .init(.fontFamily, .appearance, "Font family",
              "typeface monospace ligatures sf mono jetbrains"),
        .init(.fontSize, .appearance, "Font size",
              "points bigger smaller larger zoom text"),
        .init(.strokeWeight, .appearance, "Stroke weight",
              "thin thick bold smoothing antialiasing weight faint blurry"),
        .init(.lineHeight, .appearance, "Line spacing",
              "leading line height density cramped rows"),
        .init(.blinkCursor, .appearance, "Blink cursor",
              "caret flashing pulse"),

        // Profiles
        .init(.profileList, .profiles, "Profiles",
              "list shells startup"),
        .init(.profileAdd, .profiles, "Add a profile", "new create"),
        .init(.profileRemove, .profiles, "Remove a profile", "delete"),
        .init(.profileMoveUp, .profiles, "Move a profile up", "order reorder"),
        .init(.profileMoveDown, .profiles, "Move a profile down", "order reorder"),
        .init(.profileName, .profiles, "Profile name", "rename title"),
        .init(.profileCommand, .profiles, "Profile command",
              "shell login zsh bash fish program run"),
        .init(.profileDirectory, .profiles, "Profile starting directory",
              "cwd folder path working home"),
        .init(.profileChooseDirectory, .profiles, "Choose a starting directory",
              "cwd folder path browse"),
        .init(.profileTheme, .profiles, "Profile theme",
              "colours colors override pin per-profile"),
        .init(.profileDefault, .profiles, "Default profile",
              "cmd-t new tab default"),
        .init(.profileEnvAdd, .profiles, "Environment variables",
              "env var export path setenv"),

        // Triggers
        .init(.triggerList, .triggers, "Triggers",
              "list rules regex highlight links"),
        .init(.triggerAdd, .triggers, "Add a trigger", "new create rule"),
        .init(.triggerRemove, .triggers, "Remove a trigger", "delete rule"),
        .init(.triggerMoveUp, .triggers, "Move a trigger up", "order priority"),
        .init(.triggerMoveDown, .triggers, "Move a trigger down", "order priority"),
        .init(.triggerEnabled, .triggers, "Trigger enabled", "on off disable turn"),
        .init(.triggerName, .triggers, "Trigger name", "rename title"),
        .init(.triggerPattern, .triggers, "Trigger pattern",
              "regex regular expression match"),
        .init(.triggerSample, .triggers, "Test a trigger",
              "regex tester sample try preview"),
        .init(.triggerStyle, .triggers, "Trigger style",
              "highlight underline background colour color text"),
        .init(.triggerColor, .triggers, "Trigger colour",
              "color highlight tint"),
        .init(.triggerAction, .triggers, "Trigger ⌘-click action",
              "command click open url reveal finder run"),
        .init(.triggerCommand, .triggers, "Trigger command",
              "run shell execute template"),

        // General
        .init(.warnOnClose, .general, "Warn before closing a tab with a running process",
              "confirm prompt quit close vim ssh"),
        .init(.scrollbackLines, .general, "Lines kept per tab",
              "scrollback history buffer memory lines depth"),
        .init(.shellIntegration, .general, "Track the prompt and working directory",
              "shell integration osc 133 osc 7 prompt marks jump cwd zsh bash fish"),

        // Notifications
        .init(.notificationsEnabled, .notifications, "Enable notifications",
              "banner alert macos notify"),
        .init(.notifyOnBell, .notifications, "Notify on terminal bell",
              "bel alert sound claude code waiting"),
        .init(.notifyOnlyWhenUnfocused, .notifications, "Only when the tab isn't focused",
              "background inactive unfocused"),
    ]

    /// One pane's controls, in layout order. The Tab traversal in
    /// `SettingsView` walks this.
    static func fields(in category: SettingsCategory) -> [SettingsField] {
        all.filter { $0.category == category }.map(\.field)
    }

    /// Entries matching `query`, best first.
    ///
    /// Ranked rather than merely filtered, because the useful answer to "font"
    /// is the font controls before "Default profile" — which mentions a font
    /// nowhere but sits in a pane whose name matched. A label match always
    /// beats a keyword match, and a keyword match always beats a pane-name
    /// match; ties keep the index's own order, which is the panes' order.
    static func search(_ query: String) -> [SettingsEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }

        return all.enumerated().compactMap { position, entry -> (Int, Int, SettingsEntry)? in
            guard let rank = rank(entry, query: q) else { return nil }
            return (rank, position, entry)
        }
        .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        .map(\.2)
    }

    private static func rank(_ entry: SettingsEntry, query q: String) -> Int? {
        let label = entry.label.lowercased()
        if label.hasPrefix(q) { return 0 }
        // A word inside the label — "closing" should find "Warn before
        // closing a tab…" as strongly as the first word would.
        if label.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains(where: { $0.hasPrefix(q) }) { return 1 }
        if label.contains(q) { return 2 }
        if entry.keywords.contains(where: { $0.hasPrefix(q) }) { return 3 }
        if entry.keywords.contains(where: { $0.contains(q) }) { return 4 }
        if entry.category.title.lowercased().hasPrefix(q) { return 5 }
        return nil
    }
}
