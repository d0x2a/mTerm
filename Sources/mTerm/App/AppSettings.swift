import Foundation

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case light, dark, system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light:  return "Light"
        case .dark:   return "Dark"
        case .system: return "Follow System"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var appearanceMode: AppearanceMode = .system
    var lightThemeId: String = Theme.mTermLight.id
    var darkThemeId: String = Theme.mTermDark.id
    var fontFamily: String = FontCatalog.defaultFamily
    var fontSize: Double = 14
    /// 0.0 = no stem-darkening (truest CoreText anti-aliasing, can read as
    /// "too thin" on dark themes); 1.0 ≈ macOS's old CG font-smoothing dilation.
    ///
    /// 1.0 is the default because anything less reads as washed out next to
    /// Terminal.app. Measured on the same font and size (JetBrains Mono 13pt),
    /// the old 0.5 default laid down 8.4% less ink than CoreGraphics' own
    /// smoothing and rendered 13% of stems as single hairline pixels where
    /// Terminal.app renders barely 1%. At 1.0 total coverage matches CG to
    /// within 0.2%.
    var strokeWeight: Double = 1.0
    /// Row height as a multiple of the font's tight ascent+descent box.
    /// 1.0 is the classic dense terminal packing (iTerm2 / Alacritty); 1.15 is
    /// the default because that packing reads as cramped at typical sizes —
    /// at 13pt it buys 5 device pixels per row, which roughly doubles the
    /// whitespace between one row's ink and the next. Extra leading is split
    /// above and below the text.
    var lineHeight: Double = 1.15
    /// Blink the text cursor. Off by default: a steady block is what iTerm2
    /// and Alacritty ship, and a cursor that pulses twice a second is the one
    /// thing on an idle screen that keeps redrawing.
    var blinkCursor: Bool = false
    var warnOnCloseWithRunningProcess: Bool = true

    /// Master switch for macOS notifications. When off, bell and OSC 9/777
    /// notification escapes are ignored (the bell still updates the screen as
    /// usual — it just won't post a banner).
    var notificationsEnabled: Bool = true
    /// Turn a terminal bell (BEL / `\a`) into a notification. Claude Code's
    /// `terminal_bell` channel uses this to flag "waiting for your input".
    var notifyOnBell: Bool = true
    /// Only post when the tab that fired the event isn't already frontmost
    /// (window key, app active, tab selected). Off = always notify.
    var notifyOnlyWhenUnfocused: Bool = true

    private enum CodingKeys: String, CodingKey {
        case appearanceMode, lightThemeId, darkThemeId, fontFamily, fontSize,
             strokeWeight, lineHeight, blinkCursor, warnOnCloseWithRunningProcess,
             notificationsEnabled, notifyOnBell, notifyOnlyWhenUnfocused
        /// Read-only key for migrating old settings; we never write it back.
        case thinStrokes
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(appearanceMode, forKey: .appearanceMode)
        try c.encode(lightThemeId, forKey: .lightThemeId)
        try c.encode(darkThemeId, forKey: .darkThemeId)
        try c.encode(fontFamily, forKey: .fontFamily)
        try c.encode(fontSize, forKey: .fontSize)
        try c.encode(strokeWeight, forKey: .strokeWeight)
        try c.encode(lineHeight, forKey: .lineHeight)
        try c.encode(blinkCursor, forKey: .blinkCursor)
        try c.encode(warnOnCloseWithRunningProcess, forKey: .warnOnCloseWithRunningProcess)
        try c.encode(notificationsEnabled, forKey: .notificationsEnabled)
        try c.encode(notifyOnBell, forKey: .notifyOnBell)
        try c.encode(notifyOnlyWhenUnfocused, forKey: .notifyOnlyWhenUnfocused)
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.appearanceMode = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearanceMode) ?? .system
        self.lightThemeId   = try c.decodeIfPresent(String.self, forKey: .lightThemeId) ?? Theme.mTermLight.id
        self.darkThemeId    = try c.decodeIfPresent(String.self, forKey: .darkThemeId) ?? Theme.mTermDark.id
        self.fontFamily     = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? FontCatalog.defaultFamily
        self.fontSize       = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 14
        // Prefer the new continuous strokeWeight; migrate the legacy
        // thinStrokes bool when only the old key is present.
        if let weight = try c.decodeIfPresent(Double.self, forKey: .strokeWeight) {
            self.strokeWeight = weight
        } else if let thin = try c.decodeIfPresent(Bool.self, forKey: .thinStrokes) {
            self.strokeWeight = thin ? 0.0 : 1.0
        } else {
            self.strokeWeight = 1.0
        }
        // Settings files written before line spacing existed have no key, so
        // they adopt the new default rather than staying pinned to 1.0.
        self.lineHeight =
            try c.decodeIfPresent(Double.self, forKey: .lineHeight) ?? 1.15
        // Absent from settings files written before this existed, which take
        // the new default and stop blinking.
        self.blinkCursor = try c.decodeIfPresent(Bool.self, forKey: .blinkCursor) ?? false
        self.warnOnCloseWithRunningProcess =
            try c.decodeIfPresent(Bool.self, forKey: .warnOnCloseWithRunningProcess) ?? true
        self.notificationsEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        self.notifyOnBell =
            try c.decodeIfPresent(Bool.self, forKey: .notifyOnBell) ?? true
        self.notifyOnlyWhenUnfocused =
            try c.decodeIfPresent(Bool.self, forKey: .notifyOnlyWhenUnfocused) ?? true
    }
}

extension AppSettings {
    private static var url: URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("mTerm", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    static func load() -> AppSettings {
        guard let url = url,
              let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return s
    }

    static func save(_ settings: AppSettings) {
        guard let url = url,
              let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
