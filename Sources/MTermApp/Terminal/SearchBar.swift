import AppKit

final class SearchBar: NSVisualEffectView, NSSearchFieldDelegate {
    let field = NSSearchField()
    let regexToggle = NSButton(checkboxWithTitle: ".*", target: nil, action: nil)
    let countLabel = NSTextField(labelWithString: "")
    let prevBtn = NSButton(title: "↑", target: nil, action: nil)
    let nextBtn = NSButton(title: "↓", target: nil, action: nil)
    let closeBtn = NSButton(title: "✕", target: nil, action: nil)

    var onQuery: ((String, Bool) -> Void)?
    var onPrev: (() -> Void)?
    var onNext: (() -> Void)?
    var onClose: (() -> Void)?

    var matchCount: Int = 0 { didSet { refreshCount() } }
    var currentMatch: Int = 0 { didSet { refreshCount() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .titlebar
        blendingMode = .withinWindow
        state = .active

        field.delegate = self
        field.placeholderString = "Search"
        field.target = self
        field.action = #selector(performSearch(_:))
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        regexToggle.target = self
        regexToggle.action = #selector(regexToggled(_:))
        regexToggle.toolTip = "Use regular expression"

        countLabel.font = NSFont.systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.lineBreakMode = .byTruncatingTail

        for btn in [prevBtn, nextBtn, closeBtn] {
            btn.bezelStyle = .roundRect
            btn.controlSize = .small
            btn.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        }
        prevBtn.target = self;  prevBtn.action  = #selector(prevTapped(_:))
        nextBtn.target = self;  nextBtn.action  = #selector(nextTapped(_:))
        closeBtn.target = self; closeBtn.action = #selector(closeTapped(_:))
        prevBtn.toolTip = "Previous match (⇧⌘G)"
        nextBtn.toolTip = "Next match (⌘G)"
        closeBtn.toolTip = "Close search (Esc)"

        let stack = NSStackView(views: [field, regexToggle, countLabel, prevBtn, nextBtn, closeBtn])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func focus() {
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    private func refreshCount() {
        if matchCount == 0 {
            countLabel.stringValue = field.stringValue.isEmpty ? "" : "no matches"
        } else {
            countLabel.stringValue = "\(currentMatch + 1) of \(matchCount)"
        }
    }

    @objc private func performSearch(_ sender: Any?) {
        onQuery?(field.stringValue, regexToggle.state == .on)
    }

    @objc private func regexToggled(_ sender: Any?) {
        onQuery?(field.stringValue, regexToggle.state == .on)
    }

    @objc private func prevTapped(_ sender: Any?)  { onPrev?() }
    @objc private func nextTapped(_ sender: Any?)  { onNext?() }
    @objc private func closeTapped(_ sender: Any?) { onClose?() }

    // NSSearchFieldDelegate / NSControlTextEditingDelegate
    func control(_ control: NSControl,
                 textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            onNext?()
            return true
        case #selector(NSResponder.insertBacktab(_:)):    // ⇧↩
            onPrev?()
            return true
        default:
            return false
        }
    }
}
