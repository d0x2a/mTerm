import Foundation

/// Encodes mouse events the way the child asked for them. Kept out of the view
/// so the wire format can be exercised without a window.
enum MouseReport {
    enum Kind {
        case press, release, drag, motion
    }

    /// Button numbers as they appear on the wire.
    static let left = 0
    static let middle = 1
    static let right = 2
    /// The "no button" code that bare-motion reports carry.
    static let none = 3
    static let wheelUp = 64
    static let wheelDown = 65

    /// Returns nil when the active mode doesn't want this event, or when the
    /// legacy framing can't describe the position. A nil result still means the
    /// child owns the event — the caller shouldn't fall back to selecting.
    static func bytes(kind: Kind,
                      button: Int,
                      col: Int,
                      row: Int,
                      option: Bool = false,
                      control: Bool = false,
                      tracking: MouseTracking,
                      encoding: MouseEncoding) -> [UInt8]? {
        guard tracking != .off else { return nil }
        switch kind {
        case .press:
            break
        case .release:
            if tracking == .x10 { return nil }       // X10 reports presses only
        case .drag:
            if tracking == .x10 || tracking == .normal { return nil }
        case .motion:
            if tracking != .anyEvent { return nil }
        }

        var code = button
        if kind == .drag || kind == .motion { code += 32 }
        if option  { code += 8 }
        if control { code += 16 }

        let x = col + 1
        let y = row + 1
        switch encoding {
        case .sgr:
            let final = kind == .release ? "m" : "M"
            return Array("\u{1B}[<\(code);\(x);\(y)\(final)".utf8)
        case .x10:
            // Every field is offset by 32, so this framing simply can't
            // describe a position past column or row 223.
            guard x <= 223, y <= 223 else { return nil }
            // Legacy release says "a button came up", never which one.
            let b = kind == .release ? (code & ~3) | 3 : code
            return [0x1B, 0x5B, 0x4D, UInt8(32 + b), UInt8(32 + x), UInt8(32 + y)]
        }
    }
}
