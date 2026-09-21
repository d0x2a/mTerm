import Foundation

/// Modifier state, independent of any event class.
package struct KeyModifiers: OptionSet {
    package let rawValue: UInt8
    package init(rawValue: UInt8) { self.rawValue = rawValue }

    package static let shift   = KeyModifiers(rawValue: 1 << 0)
    package static let control = KeyModifiers(rawValue: 1 << 1)
    package static let option  = KeyModifiers(rawValue: 1 << 2)
    package static let command = KeyModifiers(rawValue: 1 << 3)
}

/// A keystroke described in terms a terminal cares about.
///
/// The host decides *which* key was pressed — virtual key codes are AppKit's
/// and UIKit's own business, and they don't agree — and this describes the
/// result in a way both can produce. `characters` is the text the key would
/// type with its modifiers applied (so Ctrl-C already arrives as 0x03);
/// `charactersIgnoringModifiers` is the bare key, which is what Option-as-Meta
/// needs.
package struct KeyChord {
    /// Named keys that have no text of their own.
    package enum Special {
        case enter, backspace, forwardDelete, tab, escape
        case up, down, left, right
        case home, end, pageUp, pageDown
    }

    package var special: Special?
    package var characters: String?
    package var charactersIgnoringModifiers: String?
    package var modifiers: KeyModifiers

    package init(special: Special? = nil,
                 characters: String? = nil,
                 charactersIgnoringModifiers: String? = nil,
                 modifiers: KeyModifiers = []) {
        self.special = special
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.modifiers = modifiers
    }
}

/// Turns a keystroke into the bytes a terminal child expects.
///
/// Lifted out of `TerminalView.bytesForKey` so it isn't tied to `NSEvent`:
/// the rules about Shift-Tab being `CSI Z` and Option meaning Meta are the
/// same wherever the keystroke came from, and a remote client has to produce
/// exactly these bytes or the shell behaves differently than it does locally.
package enum KeyEncoder {
    package static func bytes(for chord: KeyChord) -> [UInt8] {
        let mods = chord.modifiers
        let opt = mods.contains(.option)
        let shift = mods.contains(.shift)

        // ⌘-anything is an app shortcut, never terminal input. When the matching
        // menu item is disabled (⌘C with no selection, say), AppKit stops
        // handling the key equivalent and the event falls through to keyDown —
        // without this the bare letter would be typed into the shell.
        if mods.contains(.command) { return [] }

        switch chord.special {
        case .enter:
            // Shift+Enter and Option+Enter emit Alt-Return (ESC CR) so
            // TUIs like Claude Code can distinguish "newline" from
            // "submit". Plain Enter stays as CR.
            if opt || shift { return [0x1B, 0x0D] }
            return [0x0D]
        case .backspace:
            return opt ? [0x1B, 0x7F] : [0x7F]
        case .forwardDelete:
            return [0x1B, 0x5B, 0x33, 0x7E]         // CSI 3 ~
        case .tab:
            return shift ? [0x1B, 0x5B, 0x5A] : [0x09]    // Shift+Tab → CSI Z
        case .escape:
            return [0x1B]
        case .up:   return cursorBytes(final: 0x41, mods: mods)
        case .down: return cursorBytes(final: 0x42, mods: mods)
        case .right:
            if opt { return [0x1B, 0x66] }          // ESC f — forward-word
            return cursorBytes(final: 0x43, mods: mods)
        case .left:
            if opt { return [0x1B, 0x62] }          // ESC b — backward-word
            return cursorBytes(final: 0x44, mods: mods)
        case .home:     return [0x1B, 0x5B, 0x48]               // CSI H
        case .end:      return [0x1B, 0x5B, 0x46]               // CSI F
        case .pageUp:   return [0x1B, 0x5B, 0x35, 0x7E]         // CSI 5 ~
        case .pageDown: return [0x1B, 0x5B, 0x36, 0x7E]         // CSI 6 ~
        case nil:       break
        }

        // Option held but not a special key → treat Option as Meta and prefix ESC
        // to the un-Option-modified character. This is what readline / zsh ZLE
        // expect (so M-b, M-f, M-d, etc. work).
        if opt {
            guard let raw = chord.charactersIgnoringModifiers, !raw.isEmpty else { return [] }
            let s = shift ? raw : raw.lowercased()
            return [0x1B] + Array(s.utf8)
        }

        // Regular keys. Ctrl-letter already comes through as the control byte
        // (Ctrl-C → 0x03 etc.) in `characters`.
        guard let chars = chord.characters, !chars.isEmpty else { return [] }
        return Array(chars.utf8)
    }

    /// xterm-style cursor key with optional modifier encoding:
    /// CSI <final>             when no modifiers
    /// CSI 1 ; <code> <final>  where code = 1 + shift + 2·option + 4·control
    private static func cursorBytes(final: UInt8, mods: KeyModifiers) -> [UInt8] {
        var code = 1
        if mods.contains(.shift)   { code += 1 }
        if mods.contains(.option)  { code += 2 }
        if mods.contains(.control) { code += 4 }
        if code == 1 {
            return [0x1B, 0x5B, final]
        }
        return [0x1B, 0x5B, 0x31, 0x3B] + Array(String(code).utf8) + [final]
    }
}
