import AppKit

protocol SidebarDelegate: AnyObject {
    func sidebarDidSelect(tabId: UUID)
    func sidebarDidRequestClose(tabId: UUID)
    /// `toIndex` is the gap index in the pre-move array — i.e. 0 means
    /// "above the first row," N means "below the last row," k for 0<k<N
    /// means "between row k-1 and row k." Callers do their own
    /// remove-then-insert with the appropriate offset adjustment.
    func sidebarDidReorderTab(tabId: UUID, toIndex: Int)
}

extension NSPasteboard.PasteboardType {
    static let mTermTab = NSPasteboard.PasteboardType("com.d0x2a.mTerm.tab")
}

/// Layout constants shared between the row views and the drop-indicator math.
private enum SidebarMetrics {
    static let rowHeight: CGFloat = 26
    static let topInset: CGFloat = 4
}

final class SidebarView: NSView {
    weak var delegate: SidebarDelegate?

    private let scrollView = NSScrollView()
    private let document = SidebarDocumentView()
    private let stack = NSStackView()
    private var rows: [TabRowView] = []
    private let dropIndicator = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(
            top: SidebarMetrics.topInset, left: 0,
            bottom: SidebarMetrics.topInset, right: 0
        )
        stack.translatesAutoresizingMaskIntoConstraints = false

        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),
        ])

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = document
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        dropIndicator.wantsLayer = true
        dropIndicator.layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(0.18).cgColor
        dropIndicator.layer?.borderColor = NSColor.controlAccentColor
            .withAlphaComponent(0.55).cgColor
        dropIndicator.layer?.borderWidth = 1
        dropIndicator.layer?.cornerRadius = 4
        dropIndicator.isHidden = true
        document.addSubview(dropIndicator)

        document.registerForDraggedTypes([.mTermTab])
        document.onDragChanged = { [weak self] point in
            self?.handleDragChanged(at: point) ?? false
        }
        document.onDragPerform = { [weak self] point, info in
            self?.handleDrop(at: point, info: info) ?? false
        }
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
        // Keep the indicator above the new rows.
        document.addSubview(dropIndicator)
    }

    // MARK: drop logic

    private func handleDragChanged(at point: NSPoint?) -> Bool {
        guard rows.count > 1, let point else {
            dropIndicator.isHidden = true
            return false
        }
        let index = targetIndex(for: point.y)
        showDropIndicator(at: index)
        return true
    }

    private func handleDrop(at point: NSPoint, info: NSDraggingInfo) -> Bool {
        dropIndicator.isHidden = true
        guard rows.count > 1 else { return false }
        let index = targetIndex(for: point.y)
        guard let str = info.draggingPasteboard.string(forType: .mTermTab),
              let uuid = UUID(uuidString: str) else { return false }
        delegate?.sidebarDidReorderTab(tabId: uuid, toIndex: index)
        return true
    }

    /// Maps a y-coordinate inside the document view to a gap index. Each row
    /// is split at its midpoint: above the midpoint inserts before that row;
    /// below inserts after.
    private func targetIndex(for y: CGFloat) -> Int {
        let h = SidebarMetrics.rowHeight
        let inset = SidebarMetrics.topInset
        let raw = (y - inset) / h
        let idx = Int(raw.rounded())
        return max(0, min(rows.count, idx))
    }

    private func showDropIndicator(at index: Int) {
        let h = SidebarMetrics.rowHeight
        let inset = SidebarMetrics.topInset
        let y = inset + CGFloat(index) * h
        let width = document.bounds.width - 8
        dropIndicator.frame = NSRect(x: 4, y: y, width: max(0, width), height: h)
        dropIndicator.isHidden = false
    }
}

/// Flipped document view that also serves as the drag-and-drop destination.
/// Forwards drag callbacks to SidebarView via closures so the destination
/// logic can live next to the row layout it controls.
private final class SidebarDocumentView: NSView {
    override var isFlipped: Bool { true }

    /// Returns whether the drop is acceptable at this point. `nil` means
    /// the drag exited the view.
    var onDragChanged: ((NSPoint?) -> Bool)?
    /// Returns whether the drop was accepted and consumed.
    var onDragPerform: ((NSPoint, NSDraggingInfo) -> Bool)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pt = convert(sender.draggingLocation, from: nil)
        return (onDragChanged?(pt) ?? false) ? .move : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pt = convert(sender.draggingLocation, from: nil)
        return (onDragChanged?(pt) ?? false) ? .move : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        _ = onDragChanged?(nil)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pt = convert(sender.draggingLocation, from: nil)
        return onDragPerform?(pt, sender) ?? false
    }
}

final class TabRowView: NSView, NSDraggingSource {
    let id: UUID
    private let highlight = NSView()
    private let label = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let closeBtn = NSButton()
    private let isActive: Bool
    private let badgeText: String?
    private var hover = false { didSet { refreshAppearance() } }
    private var trackingArea: NSTrackingArea?

    /// Set in mouseDown; consumed in mouseUp (as a click) or in mouseDragged
    /// (to start a drag). Nil means no pending press is being tracked.
    private var pressDownLocation: NSPoint?
    private static let dragThreshold: CGFloat = 4

    var onSelect: (() -> Void)?
    var onClose:  (() -> Void)?

    init(id: UUID, title: String, isActive: Bool, badge: String? = nil) {
        self.id = id
        self.isActive = isActive
        self.badgeText = badge
        super.init(frame: .zero)

        wantsLayer = true

        // Inset + rounded background for the active/hover highlight. Sits
        // behind the label/badge/close button so they read on top of it.
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 5
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)

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

        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: badgeLabel.leadingAnchor, constant: -6),

            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeBtn.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(equalToConstant: SidebarMetrics.rowHeight),
        ])

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

    // MARK: click / drag disambiguation

    override func mouseDown(with event: NSEvent) {
        pressDownLocation = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressDownLocation else { return }
        let dx = event.locationInWindow.x - start.x
        let dy = event.locationInWindow.y - start.y
        let dist2 = dx * dx + dy * dy
        guard dist2 >= Self.dragThreshold * Self.dragThreshold else { return }

        pressDownLocation = nil          // consume — mouseUp won't fire onSelect.
        beginTabDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if pressDownLocation != nil {
            pressDownLocation = nil
            onSelect?()
        }
    }

    private func beginTabDrag(with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(id.uuidString, forType: .mTermTab)

        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(bounds, contents: rowSnapshot())

        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    private func rowSnapshot() -> NSImage {
        let rep = bitmapImageRepForCachingDisplay(in: bounds)!
        cacheDisplay(in: bounds, to: rep)
        let img = NSImage(size: bounds.size)
        img.addRepresentation(rep)
        return img
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    /// Dim the source row while a drag is in flight so the drop indicator
    /// reads clearly even when it overlaps neighboring slots.
    func draggingSession(_ session: NSDraggingSession,
                         willBeginAt screenPoint: NSPoint) {
        alphaValue = 0.3
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        alphaValue = 1.0
    }

    // MARK: appearance

    private func refreshAppearance() {
        if isActive {
            highlight.layer?.backgroundColor = NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
            highlight.isHidden = false
            label.textColor = .labelColor
        } else if hover {
            highlight.layer?.backgroundColor = NSColor.unemphasizedSelectedContentBackgroundColor
                .withAlphaComponent(0.5).cgColor
            highlight.isHidden = false
            label.textColor = .labelColor
        } else {
            highlight.isHidden = true
            label.textColor = .secondaryLabelColor
        }
        closeBtn.isHidden = !hover
        badgeLabel.isHidden = hover || badgeText == nil
    }

    @objc private func closeAction(_ sender: Any)  { onClose?() }
}
