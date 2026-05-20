import AppKit

protocol SidebarDelegate: AnyObject {
    func sidebarDidSelect(tabId: UUID)
    func sidebarDidRequestClose(tabId: UUID)
}

final class SidebarView: NSView {
    weak var delegate: SidebarDelegate?

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private var rows: [TabRowView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let flippedDoc = FlippedView()
        flippedDoc.translatesAutoresizingMaskIntoConstraints = false
        flippedDoc.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: flippedDoc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: flippedDoc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: flippedDoc.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: flippedDoc.bottomAnchor),
        ])

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = flippedDoc
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            flippedDoc.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(tabs: [(id: UUID, title: String)], activeId: UUID?) {
        rows.forEach { $0.removeFromSuperview() }
        rows.removeAll(keepingCapacity: true)
        let count = tabs.count
        for (idx, tab) in tabs.enumerated() {
            let badge: String?
            if idx < 8 {
                badge = "⌘\(idx + 1)"
            } else if idx == count - 1 {
                badge = "⌘9"           // ⌘9 jumps to the last tab
            } else {
                badge = nil
            }
            let row = TabRowView(id: tab.id, title: tab.title,
                                 isActive: tab.id == activeId, badge: badge)
            row.onSelect = { [weak self] in self?.delegate?.sidebarDidSelect(tabId: tab.id) }
            row.onClose  = { [weak self] in self?.delegate?.sidebarDidRequestClose(tabId: tab.id) }
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            rows.append(row)
        }
    }
}

/// NSScrollView's documentView defaults to a non-flipped coordinate system,
/// which makes top-aligned content slide to the bottom when there's empty
/// vertical space. Flipping puts (0, 0) at the top so the stack stays put.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class TabRowView: NSView {
    let id: UUID
    private let label = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let closeBtn = NSButton()
    private let isActive: Bool
    private let badgeText: String?
    private var hover = false { didSet { refreshAppearance() } }
    private var trackingArea: NSTrackingArea?

    var onSelect: (() -> Void)?
    var onClose:  (() -> Void)?

    init(id: UUID, title: String, isActive: Bool, badge: String? = nil) {
        self.id = id
        self.isActive = isActive
        self.badgeText = badge
        super.init(frame: .zero)

        wantsLayer = true

        label.stringValue = title
        label.font = NSFont.systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false

        badgeLabel.stringValue = badge ?? ""
        badgeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        badgeLabel.textColor = .tertiaryLabelColor
        badgeLabel.alignment = .right
        badgeLabel.isHidden = badge == nil
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false

        closeBtn.title = ""
        closeBtn.image = NSImage(systemSymbolName: "xmark",
                                 accessibilityDescription: "Close tab")
        closeBtn.imagePosition = .imageOnly
        closeBtn.isBordered = false
        closeBtn.controlSize = .small
        closeBtn.target = self
        closeBtn.action = #selector(closeAction(_:))
        closeBtn.isHidden = true     // hover-only
        closeBtn.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(badgeLabel)
        addSubview(closeBtn)

        // Badge and close button occupy the same trailing slot — only one is
        // visible at a time (close on hover, badge otherwise).
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: badgeLabel.leadingAnchor, constant: -6),

            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeBtn.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(equalToConstant: 26),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(selectAction(_:)))
        addGestureRecognizer(click)

        refreshAppearance()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent)  { hover = false }

    private func refreshAppearance() {
        if isActive {
            layer?.backgroundColor = NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
            label.textColor = .labelColor
        } else if hover {
            layer?.backgroundColor = NSColor.unemphasizedSelectedContentBackgroundColor
                .withAlphaComponent(0.4).cgColor
            label.textColor = .labelColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            label.textColor = .secondaryLabelColor
        }
        closeBtn.isHidden = !hover
        badgeLabel.isHidden = hover || badgeText == nil
    }

    @objc private func selectAction(_ sender: Any) { onSelect?() }
    @objc private func closeAction(_ sender: Any)  { onClose?() }
}
