import AppKit

extension NSAlert {
    /// Makes Tab cycle only between the alert's buttons.
    ///
    /// By default (with Full Keyboard Access on) Tab also lands on the
    /// selectable message/informative labels, highlighting their text instead
    /// of moving between the buttons. We pull those labels out of the key view
    /// loop and wire the buttons into a closed loop so Tab toggles button↔button
    /// the way a native confirmation dialog should.
    ///
    /// Call this after the buttons are added and before presenting the alert.
    func enableButtonKeyboardNavigation() {
        layout() // Build the window's view hierarchy so we can traverse it.

        if let contentView = window.contentView {
            removeTextFieldsFromKeyLoop(in: contentView)
        }

        let buttons = buttons
        guard buttons.count >= 2 else { return }
        for (index, button) in buttons.enumerated() {
            button.refusesFirstResponder = false
            button.nextKeyView = buttons[(index + 1) % buttons.count]
        }
        window.initialFirstResponder = buttons.first
    }

    /// Appends the key-equivalent glyph to each button's title — ⏎ for the
    /// default (Return) button, ⎋ for the Cancel (Escape) button — so the
    /// dialog hints which key triggers which action. The glyph is slightly
    /// dimmed so it reads as an annotation rather than part of the label.
    ///
    /// Dimming needs an attributed title, which means we also have to set the
    /// base text color explicitly: the active default button draws white on the
    /// accent color, while ordinary buttons use the standard label color. We
    /// match each base and dim the glyph relative to it.
    ///
    /// Call this only once per alert, before presenting.
    func appendKeyEquivalentHints() {
        for button in buttons {
            let glyph: String
            switch button.keyEquivalent {
            case "\r", "\n", "\u{3}": glyph = "\u{23CE}" // ⏎ Return
            case "\u{1b}": glyph = "\u{238B}" // ⎋ Escape
            default: continue
            }
            let isDefault = button.keyEquivalent != "\u{1b}"
            let baseColor: NSColor = isDefault ? .alternateSelectedControlTextColor : .labelColor
            let glyphColor = baseColor.withAlphaComponent(0.55)
            let title = NSMutableAttributedString(
                string: button.title,
                attributes: [.foregroundColor: baseColor]
            )
            title.append(NSAttributedString(
                string: "  \(glyph)",
                attributes: [.foregroundColor: glyphColor]
            ))
            button.attributedTitle = title
        }
    }

    private func removeTextFieldsFromKeyLoop(in view: NSView) {
        for subview in view.subviews {
            if let field = subview as? NSTextField {
                field.refusesFirstResponder = true
            }
            removeTextFieldsFromKeyLoop(in: subview)
        }
    }
}
