import AppKit
import Foundation

extension Notification.Name {
    static let mTermThemeDidChange = Notification.Name("mTerm.themeDidChange")
}

/// Single source of truth for the active theme and persisted settings.
///
/// Reads happen from multiple threads (TerminalState on the session queue,
/// Renderer on the main thread). The `currentTheme` static accessor is
/// lock-protected so it's safe from any thread. Writes go through the main-
/// thread `update(settings:)` / `systemAppearanceChanged(isDark:)` methods and
/// post `mTermThemeDidChange` for observers that want to refresh.
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    @Published private(set) var current: Theme
    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            AppSettings.save(settings)
            recompute()
        }
    }

    private var cachedIsDark: Bool

    // Thread-safe mirror — TerminalState/Renderer hit this from non-main threads.
    private static var _mirror: Theme = Theme.mTermDark
    private static let mirrorLock = NSLock()

    static var currentTheme: Theme {
        mirrorLock.lock(); defer { mirrorLock.unlock() }
        return _mirror
    }

    private init() {
        let loaded = AppSettings.load()
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        self.settings = loaded
        self.cachedIsDark = isDark
        self.current = Self.theme(for: loaded, isDark: isDark)
        Self.setMirror(self.current)
    }

    func systemAppearanceChanged(isDark: Bool) {
        guard cachedIsDark != isDark else { return }
        cachedIsDark = isDark
        recompute()
    }

    private func recompute() {
        let new = Self.theme(for: settings, isDark: cachedIsDark)
        guard new != current else { return }
        current = new
        Self.setMirror(new)
        NotificationCenter.default.post(name: .mTermThemeDidChange, object: nil)
    }

    private static func theme(for settings: AppSettings, isDark: Bool) -> Theme {
        let id: String
        switch settings.appearanceMode {
        case .light:  id = settings.lightThemeId
        case .dark:   id = settings.darkThemeId
        case .system: id = isDark ? settings.darkThemeId : settings.lightThemeId
        }
        return Theme.byId(id)
    }

    private static func setMirror(_ theme: Theme) {
        mirrorLock.lock()
        _mirror = theme
        mirrorLock.unlock()
    }
}
