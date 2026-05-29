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
    /// 0.5 is the default — visibly bolder than 0 without overshooting iTerm.
    var strokeWeight: Double = 0.5
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
             strokeWeight, warnOnCloseWithRunningProcess,
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
            self.strokeWeight = 0.5
        }
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
