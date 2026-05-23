import Foundation
import simd

enum ThemeAppearance: String, Codable, CaseIterable {
    case light, dark
}

struct Theme: Identifiable, Equatable {
    let id: String
    let name: String
    let appearance: ThemeAppearance

    let background: SIMD4<Float>
    let foreground: SIMD4<Float>
    let cursor: SIMD4<Float>
    let selection: SIMD4<Float>
    let ansi: [SIMD4<Float>]    // 16 entries: 0-7 normal, 8-15 bright

    static func rgb(_ hex: UInt32, alpha: Float = 1.0) -> SIMD4<Float> {
        let r = Float((hex >> 16) & 0xFF) / 255.0
        let g = Float((hex >> 8)  & 0xFF) / 255.0
        let b = Float( hex        & 0xFF) / 255.0
        return SIMD4(r, g, b, alpha)
    }
}

extension Theme {
    static let builtin: [Theme] = [
        mTermDark, mTermLight,
        tomorrowNight,
        solarizedDark, solarizedLight,
        nord, dracula, gruvboxDark,
        pencilLight,
    ]

    // MARK: bundled themes

    static let mTermDark = Theme(
        id: "mterm-dark",
        name: "mTerm Dark",
        appearance: .dark,
        background: rgb(0x111418),
        foreground: rgb(0xeaebed),
        cursor:     rgb(0xeaebed),
        selection:  rgb(0x274d72, alpha: 0.55),
        ansi: [
            rgb(0x222831), rgb(0xcc6666), rgb(0x59c290), rgb(0xddae57),
            rgb(0x6cabe3), rgb(0xb084d6), rgb(0x5cbcc1), rgb(0xd9d9d9),
            rgb(0x666e7a), rgb(0xff7878), rgb(0x73e0a9), rgb(0xffd166),
            rgb(0x9cc7ff), rgb(0xd0a6f7), rgb(0x7ce0e6), rgb(0xffffff),
        ]
    )

    static let mTermLight = Theme(
        id: "mterm-light",
        name: "mTerm Light",
        appearance: .light,
        background: rgb(0xfafbfc),
        foreground: rgb(0x1f2328),
        cursor:     rgb(0x1f2328),
        selection:  rgb(0xb4d0ff, alpha: 0.55),
        ansi: [
            rgb(0x1f2328), rgb(0xc0392b), rgb(0x2e7d32), rgb(0xa37a1d),
            rgb(0x1d5fbb), rgb(0x8b3aa8), rgb(0x117a73), rgb(0x6e6e6e),
            rgb(0x8a8a8a), rgb(0xe53935), rgb(0x43a047), rgb(0xc28b1f),
            rgb(0x2477e0), rgb(0xab47bc), rgb(0x009688), rgb(0x222222),
        ]
    )

    // Chris Kempson's Tomorrow Night
    static let tomorrowNight = Theme(
        id: "tomorrow-night",
        name: "Tomorrow Night",
        appearance: .dark,
        background: rgb(0x1d1f21),
        foreground: rgb(0xc5c8c6),
        cursor:     rgb(0xaeafad),
        selection:  rgb(0x373b41, alpha: 0.7),
        ansi: [
            rgb(0x1d1f21), rgb(0xcc6666), rgb(0xb5bd68), rgb(0xf0c674),
            rgb(0x81a2be), rgb(0xb294bb), rgb(0x8abeb7), rgb(0xc5c8c6),
            rgb(0x969896), rgb(0xcc6666), rgb(0xb5bd68), rgb(0xf0c674),
            rgb(0x81a2be), rgb(0xb294bb), rgb(0x8abeb7), rgb(0xffffff),
        ]
    )

    // Ethan Schoonover's Solarized
    static let solarizedDark = Theme(
        id: "solarized-dark",
        name: "Solarized Dark",
        appearance: .dark,
        background: rgb(0x002b36),
        foreground: rgb(0x839496),
        cursor:     rgb(0x93a1a1),
        selection:  rgb(0x073642, alpha: 0.85),
        ansi: [
            rgb(0x073642), rgb(0xdc322f), rgb(0x859900), rgb(0xb58900),
            rgb(0x268bd2), rgb(0xd33682), rgb(0x2aa198), rgb(0xeee8d5),
            rgb(0x002b36), rgb(0xcb4b16), rgb(0x586e75), rgb(0x657b83),
            rgb(0x839496), rgb(0x6c71c4), rgb(0x93a1a1), rgb(0xfdf6e3),
        ]
    )

    static let solarizedLight = Theme(
        id: "solarized-light",
        name: "Solarized Light",
        appearance: .light,
        background: rgb(0xfdf6e3),
        foreground: rgb(0x657b83),
        cursor:     rgb(0x586e75),
        selection:  rgb(0xeee8d5, alpha: 0.85),
        ansi: [
            rgb(0x073642), rgb(0xdc322f), rgb(0x859900), rgb(0xb58900),
            rgb(0x268bd2), rgb(0xd33682), rgb(0x2aa198), rgb(0xeee8d5),
            rgb(0x002b36), rgb(0xcb4b16), rgb(0x586e75), rgb(0x657b83),
            rgb(0x839496), rgb(0x6c71c4), rgb(0x93a1a1), rgb(0xfdf6e3),
        ]
    )

    // Nordtheme.com Nord
    static let nord = Theme(
        id: "nord",
        name: "Nord",
        appearance: .dark,
        background: rgb(0x2e3440),
        foreground: rgb(0xd8dee9),
        cursor:     rgb(0xd8dee9),
        selection:  rgb(0x434c5e, alpha: 0.8),
        ansi: [
            rgb(0x3b4252), rgb(0xbf616a), rgb(0xa3be8c), rgb(0xebcb8b),
            rgb(0x81a1c1), rgb(0xb48ead), rgb(0x88c0d0), rgb(0xe5e9f0),
            rgb(0x4c566a), rgb(0xbf616a), rgb(0xa3be8c), rgb(0xebcb8b),
            rgb(0x81a1c1), rgb(0xb48ead), rgb(0x8fbcbb), rgb(0xeceff4),
        ]
    )

    // Dracula (draculatheme.com)
    static let dracula = Theme(
        id: "dracula",
        name: "Dracula",
        appearance: .dark,
        background: rgb(0x282a36),
        foreground: rgb(0xf8f8f2),
        cursor:     rgb(0xf8f8f0),
        selection:  rgb(0x44475a, alpha: 0.9),
        ansi: [
            rgb(0x21222c), rgb(0xff5555), rgb(0x50fa7b), rgb(0xf1fa8c),
            rgb(0xbd93f9), rgb(0xff79c6), rgb(0x8be9fd), rgb(0xf8f8f2),
            rgb(0x6272a4), rgb(0xff6e6e), rgb(0x69ff94), rgb(0xffffa5),
            rgb(0xd6acff), rgb(0xff92df), rgb(0xa4ffff), rgb(0xffffff),
        ]
    )

    // Pavel Pertsev's Gruvbox dark (medium)
    static let gruvboxDark = Theme(
        id: "gruvbox-dark",
        name: "Gruvbox Dark",
        appearance: .dark,
        background: rgb(0x282828),
        foreground: rgb(0xebdbb2),
        cursor:     rgb(0xebdbb2),
        selection:  rgb(0x504945, alpha: 0.85),
        ansi: [
            rgb(0x282828), rgb(0xcc241d), rgb(0x98971a), rgb(0xd79921),
            rgb(0x458588), rgb(0xb16286), rgb(0x689d6a), rgb(0xa89984),
            rgb(0x928374), rgb(0xfb4934), rgb(0xb8bb26), rgb(0xfabd2f),
            rgb(0x83a598), rgb(0xd3869b), rgb(0x8ec07c), rgb(0xebdbb2),
        ]
    )

    // Pencil Light — a low-contrast light palette. Bright ANSI variants
    // intentionally mirror the regular ones (the source theme uses muted
    // colors for both, so bold text changes weight without changing hue).
    static let pencilLight = Theme(
        id: "pencil-light",
        name: "Pencil Light",
        appearance: .light,
        background: rgb(0xf9f9f9),
        foreground: rgb(0x2a2c33),
        cursor:     rgb(0xbbbbbb),
        selection:  rgb(0xededed),
        ansi: [
            rgb(0x000000), rgb(0xde3e35), rgb(0x3f953a), rgb(0xd2b67c),
            rgb(0x2f5af3), rgb(0x950095), rgb(0x3f953a), rgb(0xbbbbbb),
            rgb(0x000000), rgb(0xde3e35), rgb(0x3f953a), rgb(0xd2b67c),
            rgb(0x2f5af3), rgb(0xa00095), rgb(0x3f953a), rgb(0xffffff),
        ]
    )
}

// MARK: - Imported themes (iTerm2 .itermcolors)

enum ThemeImportError: LocalizedError {
    case unreadableFile
    case malformedPlist
    case missingColors

    var errorDescription: String? {
        switch self {
        case .unreadableFile:  return "Could not read the selected file."
        case .malformedPlist:  return "The file isn't a valid property list."
        case .missingColors:   return "The file is missing one or more required color entries."
        }
    }
}

extension Theme {
    /// `~/Library/Application Support/mTerm/themes/`. Created on first access.
    static var themesDirectory: URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("mTerm/themes", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Loads every `.itermcolors` file in the themes directory.
    static func loadImported() -> [Theme] {
        guard let dir = themesDirectory else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "itermcolors" }
            .compactMap { try? importItermColors(from: $0) }
    }

    /// Parses an iTerm2 `.itermcolors` plist into a Theme. The id and name
    /// derive from the filename (so "Pencil Light.itermcolors" becomes
    /// `id: "pencil-light"`, `name: "Pencil Light"`). Appearance is guessed
    /// from background luminance.
    static func importItermColors(from url: URL) throws -> Theme {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw ThemeImportError.unreadableFile }

        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(
                from: data, format: nil
            )
        } catch { throw ThemeImportError.malformedPlist }

        guard let dict = plist as? [String: Any] else {
            throw ThemeImportError.malformedPlist
        }

        func color(_ key: String) -> SIMD4<Float>? {
            guard let entry = dict[key] as? [String: Any],
                  let r = (entry["Red Component"]   as? NSNumber)?.floatValue,
                  let g = (entry["Green Component"] as? NSNumber)?.floatValue,
                  let b = (entry["Blue Component"]  as? NSNumber)?.floatValue
            else { return nil }
            let a = (entry["Alpha Component"] as? NSNumber)?.floatValue ?? 1.0
            return SIMD4(r, g, b, a)
        }

        var ansi: [SIMD4<Float>] = []
        for i in 0..<16 {
            guard let c = color("Ansi \(i) Color") else {
                throw ThemeImportError.missingColors
            }
            ansi.append(c)
        }
        guard let bg = color("Background Color"),
              let fg = color("Foreground Color"),
              let cursor = color("Cursor Color"),
              let selection = color("Selection Color")
        else { throw ThemeImportError.missingColors }

        let name = url.deletingPathExtension().lastPathComponent
        let id = "imported-" + name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        // Quick perceptual-luminance check (Rec. 709 weights).
        let lum = 0.2126 * bg.x + 0.7152 * bg.y + 0.0722 * bg.z
        let appearance: ThemeAppearance = lum > 0.5 ? .light : .dark

        return Theme(
            id: id,
            name: name,
            appearance: appearance,
            background: bg,
            foreground: fg,
            cursor: cursor,
            selection: selection,
            ansi: ansi
        )
    }
}
