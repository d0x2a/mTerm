import AppKit
import MTermCore

/// The "copy this text?" confirmation for a coloured run.
///
/// Asks for the same reason the command sheet does — ⌘-click on text used to
/// cost nothing, and replacing the clipboard isn't something to find out
/// about by losing what was on it — but has nothing to adjust: the colour
/// drew the extent exactly. It counts characters instead, because a passage
/// set apart like this is usually a draft headed for a field with a limit.
/// And for the same reason it is sized to the text rather than scrolling:
/// a draft is read whole before it's pasted.
final class RunCopySheet {
    private let run: ColorRun
    private let theme: Theme
    /// Called once the sheet is gone, however it went, so the terminal behind
    /// it can stop marking the run.
    private let done: () -> Void
    private let copy: (String) -> Void

    private let alert = NSAlert()
    private let text = NSTextField(wrappingLabelWithString: "")

    init(run: ColorRun,
         theme: Theme,
         done: @escaping () -> Void,
         copy: @escaping (String) -> Void) {
        self.run = run
        self.theme = theme
        self.done = done
        self.copy = copy
    }

    func present(in window: NSWindow?) {
        alert.alertStyle = .informational
        alert.messageText = "Copy this text to the clipboard?"
        alert.accessoryView = buildAccessory(maxHeight: Self.maxPreviewHeight(for: window))
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\u{1b}"   // Escape
        alert.appendKeyEquivalentHints()
        alert.enableButtonKeyboardNavigation()

        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.done()
            if response == .alertFirstButtonReturn { self.copy(self.run.text) }
        }
        guard let window else {
            finish(alert.runModal())
            return
        }
        alert.beginSheetModal(for: window, completionHandler: finish)
    }

    /// What the alert's own furniture takes around the preview: icon and
    /// title above, the count and the buttons below, the sheet's margins.
    private static let alertChrome: CGFloat = 200

    /// The preview grows with the text rather than scrolling, until the sheet
    /// would outgrow the window it hangs from — a run can be forty rows of a
    /// wide terminal. Only past that does it scroll.
    private static func maxPreviewHeight(for window: NSWindow?) -> CGFloat {
        let room = window?.frame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? 800
        return max(160, room - alertChrome)
    }

    private func buildAccessory(maxHeight: CGFloat) -> NSView {
        // In the run's own colour, so the preview looks like what was pointed at.
        text.stringValue = run.text
        let (box, document) = CopyPreview.make(showing: text,
                                               in: theme,
                                               textColor: run.color.simd,
                                               height: .fitting(max: maxHeight))
        CopyPreview.fit(text, in: document)

        let n = run.text.count
        let count = NSTextField(labelWithString: n == 1 ? "1 character" : "\(n) characters")
        count.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        count.textColor = .secondaryLabelColor
        count.refusesFirstResponder = true
        count.sizeToFit()

        let height = box.frame.height + 6 + count.frame.height
        let container = NSView(frame: NSRect(x: 0, y: 0, width: CopyPreview.width, height: height))
        box.frame.origin = NSPoint(x: 0, y: height - box.frame.height)
        count.frame.origin = .zero
        container.addSubview(box)
        container.addSubview(count)
        return container
    }
}
