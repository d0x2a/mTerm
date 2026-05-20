import Foundation
import simd

enum ClickAction: Codable, Equatable {
    case openURL
    case openFile
    case runCommand(String)        // template, $1 is the matched text
}

enum TriggerStyle: String, Codable {
    case background
    case underline
    case both
}

struct Trigger: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var pattern: String
    /// Background tint color (RGBA, 0..1).
    var colorR: Float
    var colorG: Float
    var colorB: Float
    var colorA: Float
    var style: TriggerStyle
    var clickAction: ClickAction?
    var enabled: Bool

    init(id: UUID = UUID(),
         name: String,
         pattern: String,
         color: SIMD4<Float>,
         style: TriggerStyle = .background,
         clickAction: ClickAction? = nil,
         enabled: Bool = true) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.colorR = color.x
        self.colorG = color.y
        self.colorB = color.z
        self.colorA = color.w
        self.style = style
        self.clickAction = clickAction
        self.enabled = enabled
    }

    var color: SIMD4<Float> { SIMD4(colorR, colorG, colorB, colorA) }
}

extension Trigger {
    /// Sensible defaults shipped with mTerm. Mirrors iTerm's smart-selection
    /// regexes for common types — clickable URLs, paths, plus passive
    /// highlights for git SHAs and IP addresses.
    static let builtins: [Trigger] = [
        Trigger(name: "URL",
                pattern: #"(?:https?|ftp|file)://[^\s)\]>"'`]+"#,
                color: SIMD4(0.40, 0.65, 1.00, 1.00),
                style: .underline,
                clickAction: .openURL),
        Trigger(name: "File path",
                // Absolute paths require at least two components (so slash
                // commands like `/loop` aren't matched), but `~/x`, `./x`,
                // and `../x` still match as single-segment relative paths.
                pattern: #"(?:^|(?<=[\s'"`(]))(?:(?:~|\.{1,2})/[^\s:()\]>"'`]+|/[^\s:()\]>"'`/]+/[^\s:()\]>"'`]*)"#,
                color: SIMD4(0.40, 0.85, 0.55, 1.00),
                style: .underline,
                clickAction: .openFile),
        Trigger(name: "Git SHA",
                pattern: #"\b[0-9a-f]{7,40}\b"#,
                color: SIMD4(0.72, 0.55, 0.95, 0.18),
                style: .background),
        Trigger(name: "IPv4 address",
                pattern: #"\b(?:25[0-5]|2[0-4]\d|[01]?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|[01]?\d?\d)){3}\b"#,
                color: SIMD4(1.00, 0.65, 0.25, 0.18),
                style: .background),
    ]
}
