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
    /// Defaults shipped with mTerm: just URLs (clickable + ⌘-highlighted).
    /// File-path / git-SHA / IPv4 builtins used to live here but the
    /// constant highlighting under ⌘ and the accidental folder-opens on
    /// ⌘-click were noisier than they were useful. Users can add their
    /// own via the (future) Triggers editor.
    static let builtins: [Trigger] = [
        Trigger(name: "URL",
                pattern: #"(?:https?|ftp|file)://[^\s)\]>"'`]+"#,
                color: SIMD4(0.40, 0.65, 1.00, 1.00),
                style: .underline,
                clickAction: .openURL),
    ]
}
