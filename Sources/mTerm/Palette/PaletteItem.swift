import AppKit

/// What a row does when you press ⏎ on it.
enum PaletteCommand {
    /// Switch to a tab, possibly in another window.
    case switchTab(window: MainWindowController, tabId: UUID)
    /// Send an action down the responder chain, the way the menu item would.
    /// The hub owns no behaviour of its own — every action here is reachable
    /// from a menu too, which is what keeps the two from drifting apart.
    case send(Selector)
    case newTabWithProfile(UUID)
    case applyTheme(String)
    case openSetting(SettingsField)
    case tmuxNewWindow(MainWindowController)
    /// Pushes the theme stage instead of running anything.
    case drillIntoThemes
}

/// The tab-shaped fields a row needs to draw. Snapshotted when the hub opens
/// rather than read live: the list must not change shape under the selection
/// because a background tab's prompt happened to fire mid-keystroke.
struct PaletteTabInfo {
    /// 1-based position in its own window. ⌘1–9 reach the first nine.
    let index: Int
    let title: String
    /// Home-folded working directory, empty when the shell hasn't reported one.
    let directory: String
    let process: String?
    let tmuxWindowID: String?
    let wantsAttention: Bool
    let isCurrent: Bool
    /// Set only when more than one window is open, so the common case stays quiet.
    let windowLabel: String?
}

/// One searchable row.
struct PaletteItem {
    /// Also the tie-break order between sections whose best matches score
    /// equally — tabs, then actions, then themes, then settings.
    enum Kind: Int, Comparable {
        case tab = 0, action, theme, setting

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        var sectionTitle: String {
            switch self {
            case .tab:     return "Tabs"
            case .action:  return "Actions"
            case .theme:   return "Themes"
            case .setting: return "Settings"
            }
        }
    }

    let kind: Kind
    /// What the row is called, and the field a query is matched against first.
    let label: String
    /// Fields that identify the row without naming it — a tab's directory and
    /// foreground process, a setting's pane. Matched at a damped score so a
    /// secondary hit lands just under a real word-prefix on a label.
    let secondary: [String]
    /// Words someone might arrive with that appear in no field: "cls" for
    /// Clear Screen, "colours" for the themes. Same idea as SettingsIndex.
    let keywords: [String]
    let shortcut: String?
    let command: PaletteCommand
    /// Set for `.tab` rows only.
    let tab: PaletteTabInfo?
    /// Set for `.theme` rows only — drives the swatch.
    let theme: Theme?

    init(kind: Kind,
         label: String,
         secondary: [String] = [],
         keywords: String = "",
         shortcut: String? = nil,
         command: PaletteCommand,
         tab: PaletteTabInfo? = nil,
         theme: Theme? = nil) {
        self.kind = kind
        self.label = label
        self.secondary = secondary
        self.keywords = keywords.split(separator: " ").map(String.init)
        self.shortcut = shortcut
        self.command = command
        self.tab = tab
        self.theme = theme
    }
}

/// A row that survived the query, with the field it matched on so the row view
/// can bold the right characters.
struct ScoredItem {
    enum Field {
        case label
        case secondary(Int)
        /// Keywords aren't displayed, so a keyword hit highlights nothing.
        case keyword
    }

    let item: PaletteItem
    let score: Double
    let field: Field
    let match: FuzzyMatch?

    /// Ranges to bold in `item.label`, if that's where the query landed.
    var labelRanges: [Range<Int>] {
        if case .label = field { return match?.ranges ?? [] }
        return []
    }

    func ranges(forSecondary index: Int) -> [Range<Int>] {
        if case .secondary(let i) = field, i == index { return match?.ranges ?? [] }
        return []
    }
}

enum PaletteScorer {
    /// Secondary fields are damped and capped so they land just below a label
    /// word-prefix; keywords are capped lower still. Without the cap a tab
    /// whose *path* happened to start with "new" would outrank the New Tab
    /// action, which is the one ranking mistake that makes ⏎ untrustworthy.
    static let secondaryMultiplier = 0.78
    static let secondaryCeiling = 0.74
    static let keywordMultiplier = 0.7
    static let keywordCeiling = 0.6

    /// The best field of `item` for `query`, or nil if none matched.
    static func score(_ item: PaletteItem, query: [Character]) -> ScoredItem? {
        var best: ScoredItem?

        func consider(_ m: FuzzyMatch?, _ field: ScoredItem.Field,
                      multiplier: Double = 1, ceiling: Double = 1) {
            guard let m else { return }
            let s = min(m.score * multiplier, ceiling)
            if let current = best, current.score >= s { return }
            best = ScoredItem(item: item, score: s, field: field, match: m)
        }

        consider(Fuzzy.match(item.label, query: query), .label)
        for (i, value) in item.secondary.enumerated() where !value.isEmpty {
            consider(Fuzzy.match(value, query: query), .secondary(i),
                     multiplier: secondaryMultiplier, ceiling: secondaryCeiling)
        }
        for word in item.keywords {
            consider(Fuzzy.match(word, query: query), .keyword,
                     multiplier: keywordMultiplier, ceiling: keywordCeiling)
        }
        return best
    }

    /// Everything that matched, best first. Ties keep the index's own order,
    /// which is the order the sections were built in.
    static func rank(_ items: [PaletteItem], query: [Character]) -> [ScoredItem] {
        items.enumerated()
            .compactMap { position, item in
                PaletteScorer.score(item, query: query).map { (position, $0) }
            }
            .sorted { ($0.1.score, Double(-$0.0)) > ($1.1.score, Double(-$1.0)) }
            .map(\.1)
    }
}
