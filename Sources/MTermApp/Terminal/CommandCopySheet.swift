import AppKit
import MTermCore

/// The "copy this command?" confirmation, with the extent adjustable a line at
/// a time from either end.
///
/// The detector reads shapes, not shell, so it is sometimes a line out — a
/// heading it should have dropped, a trailing line it should have kept. Rather
/// than cancelling and selecting by hand, either edge can be nudged here, and
/// the command is redrawn as it moves.
///
/// Its own type because it holds state for as long as it is on screen: which
/// lines are claimed, and the controls that report it.
final class CommandCopySheet {
    /// Which edge of the extent a control moves.
    private enum Edge { case top, bottom }

    private let lines: [CommandBlockDetector.LogicalLine]
    private var span: ClosedRange<Int>
    private let theme: Theme
    /// The viewport rows now claimed, so the terminal behind the sheet can mark
    /// them. Watching the region change where it actually lives beats reading a
    /// line count. nil when the sheet is done.
    private let extentChanged: (ClosedRange<Int>?) -> Void
    private let copy: (String) -> Void

    private let alert = NSAlert()
    private let command = NSTextField(wrappingLabelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private var top: NSSegmentedControl!
    private var bottom: NSSegmentedControl!
    private var document: NSView?
    private var keyMonitor: Any?

    private static let boxWidth: CGFloat = 480
    private static let inset: CGFloat = 10
    /// Fixed, so the sheet doesn't resize under the pointer each time an edge
    /// moves. Anything longer scrolls.
    private static let visibleLines = 6

    init(lines: [CommandBlockDetector.LogicalLine],
         span: ClosedRange<Int>,
         theme: Theme,
         extentChanged: @escaping (ClosedRange<Int>?) -> Void,
         copy: @escaping (String) -> Void) {
        self.lines = lines
        self.span = span
        self.theme = theme
        self.extentChanged = extentChanged
        self.copy = copy
    }

    func present(in window: NSWindow?) {
        alert.alertStyle = .informational
        alert.messageText = "Copy this command to the clipboard?"
        alert.accessoryView = buildAccessory()
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\u{1b}"   // Escape
        alert.appendKeyEquivalentHints()
        alert.enableButtonKeyboardNavigation()
        refresh()

        // A local monitor rather than `performKeyEquivalent` on the accessory
        // view: NSView's default implementation is not a dependable hook for a
        // view this far inside an alert's hierarchy, and nothing arrived. This
        // is how the app already catches ⌘` for tab cycling.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.alert.window,
                  self.handleKey(event) else { return event }
            return nil
        }

        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if let monitor = self.keyMonitor {
                NSEvent.removeMonitor(monitor)
                self.keyMonitor = nil
            }
            self.extentChanged(nil)
            if response == .alertFirstButtonReturn { self.copy(self.currentText) }
        }
        guard let window else {
            finish(alert.runModal())
            return
        }
        alert.beginSheetModal(for: window, completionHandler: finish)
    }

    private var currentText: String {
        CommandBlockDetector.text(ofLines: span, in: lines)
    }

    // MARK: - adjusting

    private func move(_ edge: Edge, by delta: Int) {
        let lower = edge == .top ? span.lowerBound + delta : span.lowerBound
        let upper = edge == .bottom ? span.upperBound + delta : span.upperBound
        guard lower >= 0, upper <= lines.count - 1, lower <= upper else { return }
        span = lower...upper
        refresh()
    }

    /// Grow first, shrink second: each arrow points the way its edge travels.
    @objc private func topChanged(_ sender: NSSegmentedControl) {
        move(.top, by: sender.selectedSegment == 0 ? -1 : 1)
        sender.selectedSegment = -1
    }

    @objc private func bottomChanged(_ sender: NSSegmentedControl) {
        move(.bottom, by: sender.selectedSegment == 0 ? 1 : -1)
        sender.selectedSegment = -1
    }

    /// ⌥↑/⌥↓ and ⇧↑/⇧↓.
    ///
    /// The arrows carry `.function` and `.numericPad` as well as the modifier
    /// actually held, and both are inside `deviceIndependentFlagsMask` — so
    /// comparing the whole mask against `.option` never matches. Only the four
    /// modifiers anyone pressed on purpose are considered.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let key = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
        let up = Int(key.value) == NSUpArrowFunctionKey
        guard up || Int(key.value) == NSDownArrowFunctionKey else { return false }

        let held = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch held {
        case [.option]: move(.top, by: up ? -1 : 1)
        case [.shift]:  move(.bottom, by: up ? -1 : 1)
        default:        return false
        }
        return true
    }

    private func refresh() {
        command.stringValue = currentText
        let n = span.count
        count.stringValue = n == 1 ? "1 line" : "\(n) lines"

        top.setEnabled(span.lowerBound > 0, forSegment: 0)
        top.setEnabled(span.lowerBound < span.upperBound, forSegment: 1)
        bottom.setEnabled(span.upperBound < lines.count - 1, forSegment: 0)
        bottom.setEnabled(span.upperBound > span.lowerBound, forSegment: 1)

        // Re-lay the text and grow the scrolled document to match, so a
        // command longer than the box scrolls instead of being clipped.
        let width = Self.boxWidth - Self.inset * 2
        let fitted = command.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
        command.frame = NSRect(x: Self.inset, y: Self.inset, width: width, height: fitted.height)
        if let document {
            let height = max(document.superview?.frame.height ?? 0, fitted.height + Self.inset * 2)
            document.frame = NSRect(x: 0, y: 0, width: Self.boxWidth, height: height)
        }

        extentChanged(lines[span.lowerBound].firstRow...lines[span.upperBound].lastRow)
    }

    // MARK: - building

    private func color(_ c: SIMD4<Float>) -> NSColor {
        NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
    }

    private func buildAccessory() -> NSView {
        let width = Self.boxWidth
        let settings = ThemeStore.shared.settings
        let font = FontCatalog.makeFont(family: settings.fontFamily,
                                        size: settings.fontSize,
                                        scale: 1)

        // A label, not a text view: a text view takes first responder when the
        // sheet opens and then Return goes to it rather than to Copy.
        command.isSelectable = false
        command.refusesFirstResponder = true
        command.isBezeled = false
        command.drawsBackground = false
        command.font = font
        command.textColor = color(theme.foreground)
        command.maximumNumberOfLines = 0
        command.lineBreakMode = .byWordWrapping
        command.preferredMaxLayoutWidth = width - Self.inset * 2
        command.translatesAutoresizingMaskIntoConstraints = true

        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let boxHeight = ceil(lineHeight * CGFloat(Self.visibleLines)) + Self.inset * 2

        // Flipped, so the command starts at the top of the box rather than
        // sitting on its floor.
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: boxHeight))
        document.addSubview(command)
        self.document = document

        let box = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: boxHeight))
        box.documentView = document
        box.drawsBackground = true
        box.backgroundColor = color(theme.background)
        box.hasVerticalScroller = true
        box.autohidesScrollers = true
        box.wantsLayer = true
        box.layer?.cornerRadius = 6
        box.layer?.masksToBounds = true
        box.layer?.borderWidth = 1
        box.layer?.borderColor = color(theme.foreground).withAlphaComponent(0.15).cgColor

        top = NSSegmentedControl(labels: ["↑", "↓"], trackingMode: .momentary,
                                 target: self, action: #selector(topChanged(_:)))
        bottom = NSSegmentedControl(labels: ["↓", "↑"], trackingMode: .momentary,
                                    target: self, action: #selector(bottomChanged(_:)))
        top.setToolTip("Take the line above (⌥↑)", forSegment: 0)
        top.setToolTip("Drop the first line (⌥↓)", forSegment: 1)
        bottom.setToolTip("Take the line below (⇧↓)", forSegment: 0)
        bottom.setToolTip("Drop the last line (⇧↑)", forSegment: 1)
        for control in [top!, bottom!] { control.sizeToFit() }

        let topLabel = caption("Top")
        let bottomLabel = caption("Bottom")
        count.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        count.textColor = .secondaryLabelColor
        count.refusesFirstResponder = true
        let hint = caption("⌥↑ ⌥↓ move the top edge · ⇧↑ ⇧↓ the bottom")
        hint.textColor = .tertiaryLabelColor

        // Laid out by hand: the row mixes a themed box with native controls,
        // and explicit frames are easier to reason about here than a stack
        // view's implicit sizing.
        let rowHeight = max(top.frame.height, topLabel.frame.height)
        let hintHeight = hint.fittingSize.height
        let total = boxHeight + 8 + rowHeight + 4 + hintHeight

        func place(_ view: NSView, x: CGFloat, y: CGFloat) -> CGFloat {
            let size = view.fittingSize == .zero ? view.frame.size : view.fittingSize
            view.frame = NSRect(x: x, y: y + (rowHeight - size.height) / 2,
                                width: size.width, height: size.height)
            return x + size.width
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: total))
        container.addSubview(box)
        box.frame.origin = NSPoint(x: 0, y: total - boxHeight)

        var x: CGFloat = 0
        let rowY = hintHeight + 4
        x = place(topLabel, x: x, y: rowY) + 6
        x = place(top, x: x, y: rowY) + 24
        x = place(bottomLabel, x: x, y: rowY) + 6
        x = place(bottom, x: x, y: rowY) + 24
        _ = place(count, x: x, y: rowY)
        for view in [topLabel, top!, bottomLabel, bottom!, count] { container.addSubview(view) }

        hint.frame = NSRect(x: 0, y: 0, width: width, height: hintHeight)
        container.addSubview(hint)
        return container
    }

    private func caption(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.refusesFirstResponder = true
        field.sizeToFit()
        return field
    }
}

/// Top-down coordinates, so text in a scroll view starts at the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
