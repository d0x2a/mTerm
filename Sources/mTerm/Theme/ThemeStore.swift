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
    @Published private(set) var importedThemes: [Theme] = []
    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            AppSettings.save(settings)
            recompute()
        }
    }

    /// Builtins followed by user-imported themes. A builtin id wins over
    /// a user theme with the same id (the user can always rename their
    /// file to avoid the conflict).
    var allThemes: [Theme] {
        var seen = Set<String>()
        return (Theme.builtin + importedThemes)
            .filter { seen.insert($0.id).inserted }
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
        let imported = Theme.loadImported()
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        self.settings = loaded
        self.importedThemes = imported
        self.cachedIsDark = isDark
        self.current = Self.theme(for: loaded, isDark: isDark,
                                  available: Theme.builtin + imported)
        Self.setMirror(self.current)
    }

    /// Copies an `.itermcolors` file into the themes directory, reparses it,
    /// refreshes `importedThemes`, and returns the resulting Theme so callers
    /// can select it. Throws ThemeImportError on parse failure.
    @discardableResult
    func importTheme(from sourceURL: URL) throws -> Theme {
        guard let dir = Theme.themesDirectory else {
            throw ThemeImportError.unreadableFile
        }
        let dest = dir.appendingPathComponent(sourceURL.lastPathComponent)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            try? fm.removeItem(at: dest)
        }
        do { try fm.copyItem(at: sourceURL, to: dest) }
        catch { throw ThemeImportError.unreadableFile }

        let theme = try Theme.importItermColors(from: dest)
        importedThemes = Theme.loadImported()
        recompute()
        return theme
    }

    func systemAppearanceChanged(isDark: Bool) {
        guard cachedIsDark != isDark else { return }
        cachedIsDark = isDark
        recompute()
    }

    private func recompute() {
        let new = Self.theme(for: settings, isDark: cachedIsDark,
                             available: allThemes)
        guard new != current else { return }
        current = new
        Self.setMirror(new)
        NotificationCenter.default.post(name: .mTermThemeDidChange, object: nil)
    }

    private static func theme(for settings: AppSettings, isDark: Bool,
                              available: [Theme]) -> Theme {
        let id: String
        switch settings.appearanceMode {
        case .light:  id = settings.lightThemeId
        case .dark:   id = settings.darkThemeId
        case .system: id = isDark ? settings.darkThemeId : settings.lightThemeId
        }
        return available.first { $0.id == id } ?? Theme.mTermDark
    }

    private static func setMirror(_ theme: Theme) {
        mirrorLock.lock()
        _mirror = theme
        mirrorLock.unlock()
    }
}
