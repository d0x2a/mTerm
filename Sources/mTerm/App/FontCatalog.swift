import AppKit

/// Curated list of monospaced fonts mTerm offers in Settings.
///
/// The first entry ("SF Mono") is the system default and is created via
/// `NSFont.monospacedSystemFont` so it works without relying on a private
/// PostScript name. The rest are looked up by PostScript name and silently
/// dropped from the picker if not installed.
enum FontCatalog {
    struct Entry: Equatable {
        let displayName: String
        let postScriptName: String   // ignored for SF Mono
    }

    static let defaultFamily = "SF Mono"

    static let curated: [Entry] = [
        Entry(displayName: "SF Mono",        postScriptName: ""),                  // system mono
        Entry(displayName: "Menlo",          postScriptName: "Menlo-Regular"),
        Entry(displayName: "Monaco",         postScriptName: "Monaco"),
        Entry(displayName: "Courier",        postScriptName: "Courier"),
        Entry(displayName: "Courier New",    postScriptName: "CourierNewPSMT"),
        Entry(displayName: "JetBrains Mono", postScriptName: "JetBrainsMono-Regular"),
        Entry(displayName: "JetBrains Mono NL", postScriptName: "JetBrainsMonoNL-Regular"),
        Entry(displayName: "Fira Code",      postScriptName: "FiraCode-Regular"),
        Entry(displayName: "Hack",           postScriptName: "Hack-Regular"),
        Entry(displayName: "Cascadia Code",  postScriptName: "CascadiaCode-Regular"),
        Entry(displayName: "IBM Plex Mono",  postScriptName: "IBMPlexMono"),
        Entry(displayName: "Source Code Pro", postScriptName: "SourceCodePro-Regular"),
        Entry(displayName: "Inconsolata",    postScriptName: "Inconsolata-Regular"),
    ]

    /// Filtered to entries actually installed. SF Mono is always present.
    static var available: [Entry] {
        curated.filter { entry in
            if entry.displayName == defaultFamily { return true }
            return NSFont(name: entry.postScriptName, size: 12) != nil
        }
    }

    /// Builds an NSFont sized for the renderer (pixel-space: `pointSize * scale`).
    /// Falls back to SF Mono if the configured family isn't available.
    static func makeFont(family: String, size: Double, scale: CGFloat) -> NSFont {
        let pixelSize = CGFloat(size) * scale
        if family == defaultFamily {
            return NSFont.monospacedSystemFont(ofSize: pixelSize, weight: .regular)
        }
        if let entry = curated.first(where: { $0.displayName == family }),
           !entry.postScriptName.isEmpty,
           let f = NSFont(name: entry.postScriptName, size: pixelSize) {
            return f
        }
        return NSFont.monospacedSystemFont(ofSize: pixelSize, weight: .regular)
    }

    static let minSize: Double = 9
    static let maxSize: Double = 28
}

/// Observable view of `FontCatalog.available`, so the Settings picker can pick
/// up a font installed after launch.
///
/// A picker reading `FontCatalog.available` directly never updates: the
/// property is a plain computed static, so SwiftUI has no dependency to
/// invalidate, and the Settings window is a reused singleton
/// (`isReleasedWhenClosed = false`) whose views are built once per process and
/// never rebuilt. Between them, the list a user sees is whatever was installed
/// the first time they opened Settings, until the app is relaunched.
///
/// A running process *does* see new fonts — CoreText refreshes and posts
/// `CTFontManagerFontChangedNotification` — so nothing here needs to outlive
/// the window. Refreshing when Settings comes to the front is enough, and
/// keeps the app from holding a font-manager observer for the whole session.
final class FontCatalogStore: ObservableObject {
    static let shared = FontCatalogStore()

    @Published private(set) var available: [FontCatalog.Entry] = FontCatalog.available

    private init() {}

    /// Re-reads the installed set. A handful of `NSFont(name:)` lookups, only
    /// on the way into Settings. Silent when nothing changed, so the common
    /// case doesn't invalidate the pane's body.
    func refresh() {
        let current = FontCatalog.available
        guard current != available else { return }
        available = current
    }
}
