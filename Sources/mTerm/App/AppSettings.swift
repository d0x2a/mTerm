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
    var thinStrokes: Bool = true
    var warnOnCloseWithRunningProcess: Bool = true

    private enum CodingKeys: String, CodingKey {
        case appearanceMode, lightThemeId, darkThemeId, fontFamily, fontSize,
             thinStrokes, warnOnCloseWithRunningProcess
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.appearanceMode = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearanceMode) ?? .system
        self.lightThemeId   = try c.decodeIfPresent(String.self, forKey: .lightThemeId) ?? Theme.mTermLight.id
        self.darkThemeId    = try c.decodeIfPresent(String.self, forKey: .darkThemeId) ?? Theme.mTermDark.id
        self.fontFamily     = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? FontCatalog.defaultFamily
        self.fontSize       = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 14
        self.thinStrokes    = try c.decodeIfPresent(Bool.self, forKey: .thinStrokes) ?? true
        self.warnOnCloseWithRunningProcess =
            try c.decodeIfPresent(Bool.self, forKey: .warnOnCloseWithRunningProcess) ?? true
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
