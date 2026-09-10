import AppKit

/// The ⌘K hub: a tab switcher that also runs actions.
///
/// Tabs and actions share one ranked list, and the *sections* are ordered by
/// their best-scoring member — so the first row is always the best answer to
/// ⏎, whichever kind it came from, and there is no precedence rule to learn.
/// With an empty query it is a recent-tabs switcher with the previously active
/// tab preselected, which makes ⌘K ⏎ a "flip back to the last tab".
final class CommandPalette: NSView, NSTextFieldDelegate {
    enum Scope: Int, CaseIterable {
        case all, tabs, actions

        var title: String {
            switch self {
            case .all:     return "All"
            case .tabs:    return "Tabs"
            case .actions: return "Actions"
            }
        }

        var next: Scope { Scope(rawValue: (rawValue + 1) % Scope.allCases.count)! }
    }

    /// The root list, or the second stage a drill-in row pushed.
    private enum Stage { case root, themes }

    static let width: CGFloat = 660
    private static let maxListHeight: CGFloat = 336

    // MARK: callbacks

    var onRun: ((PaletteCommand) -> Void)?
    /// ⌘⌫ on a tab row. The host closes the tab and calls `reload` — the hub
    /// stays open, which is what turns it into a tab manager.
    var onCloseTab: ((MainWindowController, UUID) -> Void)?
    var onDismiss: (() -> Void)?
    /// The theme to paint in. A closure rather than a stored value so a theme
    /// change — including one made from the hub's own Themes stage — repaints
    /// against the tab that is actually behind it.
    var themeProvider: (() -> Theme)?

    // MARK: views

    /// The island itself. `CommandPalette` is only its shadow host: a layer
    /// cannot both clip its content to a corner radius and cast a shadow
    /// outside those bounds, so the rounded, clipping surface is this inner
    /// view and the unclipped shadow belongs to the view around it.
    private let content = ClickSwallowingView()
    private let magnifier = NSImageView()
    private let field = NSTextField()
    private let crumb = PaletteChip()
    private let scopeChip = PaletteChip()
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let stack = NSStackView()
    private let footer = NSTextField(labelWithString: "")
    private let fieldDivider = NSView()
    private let footerDivider = NSView()
    private var listHeight: NSLayoutConstraint!

    // MARK: state

    private var rootItems: [PaletteItem] = []
    private var mru: [UUID] = []
    private var stage: Stage = .root
    private var scope: Scope = .all
    private var selection = 0
    private var rows: [ScoredItem] = []
    private var rowViews: [PaletteRowView] = []
    private var colors = PaletteColors.current()
    /// Set while the hub is tearing itself down, so the field editor ending
    /// doesn't re-enter `onDismiss`.
    private var dismissing = false
    /// Where the pointer was when the keyboard last had the selection, and
    /// whether it has moved since. Hover only takes over once the pointer
    /// physically moves — anything else lets a stationary mouse fight the
    /// keyboard for the selection, and the mouse wins every keystroke.
    private var hoverAnchor = NSEvent.mouseLocation
    private var hoverArmed = false
    /// Navigation keys are taken here rather than through the field editor's
    /// `doCommandBySelector`.
    ///
    /// A single-line NSTextField has nowhere vertical to put the insertion
    /// point, so AppKit doesn't route ↑/↓ to the field editor at all — it
    /// passes them up the responder chain, where the enclosing NSScrollView
    /// takes them and scrolls the list instead of moving the selection. The
    /// same local-monitor trick `AppDelegate.installTabCycleShortcut` uses for
    /// ⌘` is the way to see them first.
    private var keyMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The shadow host clips nothing, or it would clip its own shadow.
        layer?.masksToBounds = false

        content.wantsLayer = true
        content.layer?.cornerRadius = 11
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 1
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18)
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false

        magnifier.image = NSImage(systemSymbolName: "magnifyingglass",
                                  accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))

        crumb.isHidden = true
        crumb.onClick = { [weak self] in self?.popStage() }
        scopeChip.stringValue = "⇥ All"
        scopeChip.onClick = { [weak self] in self?.cycleScope(backwards: false) }
        scopeChip.toolTip = "Search tabs, actions, or both (⇥)"

        let fieldRow = NSStackView(views: [magnifier, crumb, field, scopeChip])
        fieldRow.orientation = .horizontal
        fieldRow.spacing = 9
        fieldRow.alignment = .centerY
        // Right inset matches the left, so the chip's outer edge sits the same
        // distance from the panel as the magnifying glass does.
        fieldRow.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        magnifier.setContentHuggingPriority(.required, for: .horizontal)
        scopeChip.setContentHuggingPriority(.required, for: .horizontal)

        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 0, bottom: 6, right: 0)

        document.addSubview(stack)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.verticalScrollElasticity = .allowed

        footer.font = .systemFont(ofSize: 11, weight: .medium)
        footer.stringValue = "↩ switch    ⌘⌫ close tab    ⇥ scope    > actions    esc close"

        for view in [fieldRow, fieldDivider, scroll, footerDivider, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        for divider in [fieldDivider, footerDivider] { divider.wantsLayer = true }

        listHeight = scroll.heightAnchor.constraint(equalToConstant: 200)
        NSLayoutConstraint.activate([
            fieldRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            fieldRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            fieldRow.topAnchor.constraint(equalTo: content.topAnchor),

            fieldDivider.topAnchor.constraint(equalTo: fieldRow.bottomAnchor),
            fieldDivider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            fieldDivider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            fieldDivider.heightAnchor.constraint(equalToConstant: 1),

            scroll.topAnchor.constraint(equalTo: fieldDivider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            listHeight,

            footerDivider.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            footerDivider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footerDivider.heightAnchor.constraint(equalToConstant: 1),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            footer.topAnchor.constraint(equalTo: footerDivider.bottomAnchor, constant: 8),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -9),

            document.topAnchor.constraint(equalTo: stack.topAnchor),
            document.bottomAnchor.constraint(equalTo: stack.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            // Without this the stack is only as wide as its widest row, and
            // every row's trailing content — the process pill, the ✕ — lines
            // up against the longest path in the list instead of the panel's
            // own edge.
            document.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: .mTermThemeDidChange, object: nil)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        removeKeyMonitor()
    }

    /// The hub is chrome, not a text surface: an arrow everywhere except the
    /// search field, whose own cursor rect sits in front of this one and wins.
    /// Needed as well as the terminal's bail-out below it, because otherwise
    /// the I-beam that was set on the way in would simply persist.
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    /// An explicit path, rebuilt with the bounds. Without one the layer infers
    /// the shadow from its contents every frame, and a layer whose own
    /// background is clear — which this host's is — infers nothing at all.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { installKeyMonitor() } else { removeKeyMonitor() }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Only while this hub owns the keyboard: the monitor is
            // app-global, and Settings or a terminal must keep its own keys.
            guard let window = self.window, window.isKeyWindow,
                  let editor = self.field.currentEditor(),
                  window.firstResponder === editor
            else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// True when the hub consumed the key. Matched on `keyCode` rather than
    /// characters so a shifted or option-modified press still routes.
    private func handleKey(_ event: NSEvent) -> Bool {
        // Arrows and the keypad set these themselves; they are not modifiers
        // anyone is holding, and leaving them in would fail every test below.
        let mods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad])
        let chars = event.charactersIgnoringModifiers?.lowercased()

        // ⌃N / ⌃P, because the people using this live in readline.
        if mods == .control, chars == "n" { move(by: 1); return true }
        if mods == .control, chars == "p" { move(by: -1); return true }

        // ⌘⌫ closes the highlighted tab and leaves the hub up.
        if mods == .command, event.keyCode == 51 {
            guard selection < rows.count,
                  case .switchTab = rows[selection].item.command else { return false }
            closeSelectedTab()
            return true
        }

        if mods == .shift, event.keyCode == 48 { cycleScope(backwards: true); return true }

        // Everything below is unmodified, so ⌘-anything still reaches the menu
        // bar — ⌘1–9 keeps meaning "jump to tab N" even with the hub open.
        guard mods.isEmpty else { return false }

        switch event.keyCode {
        case 125: move(by: 1); return true              // ↓
        case 126: move(by: -1); return true             // ↑
        case 36, 76: commit(); return true              // ↩ / keypad enter
        case 53: dismiss(); return true                 // esc
        case 48: cycleScope(backwards: false); return true
        case 51:                                        // ⌫ on an empty query
            guard field.stringValue.isEmpty else { return false }
            if stage != .root { popStage(); return true }
            if scope != .all { scope = .all; selection = 0; render(); return true }
            return false
        default: return false
        }
    }

    private func popStage() {
        guard stage != .root else { return }
        stage = .root
        selection = 0
        render()
    }

    private func cycleScope(backwards: Bool) {
        scope = backwards ? scope.next.next : scope.next
        stripSigil()
        selection = 0
        render()
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 11,
                                   cornerHeight: 11, transform: nil)
    }

    // MARK: presenting

    func reload(items: [PaletteItem], mru: [UUID]) {
        rootItems = items
        self.mru = mru
        // Before render: `themeProvider` is only set by the host after init, so
        // the colours chosen during init were the app-wide ones. Re-deriving
        // here is also what keeps a reload after ⌘⌫ painting correctly.
        applyColors()
        render()
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: 0)
    }

    /// Query as typed, minus the `>` sigil, lowercased for matching.
    private var parsedQuery: (text: [Character], scope: Scope) {
        var raw = field.stringValue
        var effective = scope
        if raw.hasPrefix(">") {
            effective = .actions
            raw.removeFirst()
        }
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return (Array(trimmed), effective)
    }

    // MARK: building the list

    private struct Section {
        let title: String
        let items: [ScoredItem]
        let best: Double
        let kind: PaletteItem.Kind
    }

    private func sections() -> [Section] {
        let (query, effectiveScope) = parsedQuery

        if stage == .themes {
            let pool = PaletteIndex.themeItems(prefixed: false)
            let items = query.isEmpty
                ? pool.map { ScoredItem(item: $0, score: 1, field: .label, match: nil) }
                : PaletteScorer.rank(pool, query: query)
            return items.isEmpty ? [] : [Section(title: "Themes", items: items,
                                                 best: 1, kind: .theme)]
        }

        if query.isEmpty { return restingSections(scope: effectiveScope) }

        let pool = rootItems.filter { item in
            switch effectiveScope {
            case .all:     return true
            case .tabs:    return item.kind == .tab
            case .actions: return item.kind != .tab
            }
        }

        var byKind: [PaletteItem.Kind: [ScoredItem]] = [:]
        for scored in PaletteScorer.rank(pool, query: query) {
            byKind[scored.item.kind, default: []].append(scored)
        }
        // Sections lead with their best member. That is the whole ranking
        // rule: no "tabs always win", so a perfect action match is never
        // buried under a fuzzy tab hit, and row 1 is always the best answer.
        return byKind
            .map { Section(title: $0.key.sectionTitle, items: $0.value,
                           best: $0.value.first?.score ?? 0, kind: $0.key) }
            .sorted { ($0.best, $1.kind) > ($1.best, $0.kind) }
    }

    /// The empty-query list. Tabs come back in most-recently-used order with
    /// the *previous* tab first and the current one last, so ⌘K ⏎ flips back
    /// to where you just were.
    private func restingSections(scope: Scope) -> [Section] {
        var out: [Section] = []

        if scope != .actions {
            let tabs = rootItems.filter { $0.kind == .tab }
            let current = tabs.filter { $0.tab?.isCurrent == true }
            let others = tabs.filter { $0.tab?.isCurrent != true }
            let ordered = others.sorted { a, b in
                rank(of: a) < rank(of: b)
            } + current
            if !ordered.isEmpty {
                out.append(Section(
                    title: "Recent tabs",
                    items: ordered.map { ScoredItem(item: $0, score: 1, field: .label, match: nil) },
                    best: 1, kind: .tab))
            }
        }

        if scope != .tabs {
            let actions = rootItems.filter { $0.kind == .action }
            let shown = scope == .actions
                ? actions
                : actions.filter { Self.restingActions.contains($0.label) }
            if !shown.isEmpty {
                out.append(Section(
                    title: scope == .actions ? "Actions" : "Frequent actions",
                    items: shown.map { ScoredItem(item: $0, score: 1, field: .label, match: nil) },
                    best: 1, kind: .action))
            }
        }
        return out
    }

    /// Position in the MRU stack; tabs the stack doesn't know about sort last
    /// but keep their window order among themselves.
    private func rank(of item: PaletteItem) -> Int {
        guard case .switchTab(_, let id) = item.command,
              let idx = mru.firstIndex(of: id) else { return Int.max }
        return idx
    }

    private static let restingActions: Set<String> = [
        "New Tab", "Change Theme…", "Find in Scrollback…", "Settings…",
    ]

    // MARK: rendering

    private func render() {
        disarmHover()
        let sections = sections()
        rows = []
        rowViews = []
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        for section in sections {
            let header = PaletteHeaderView(title: section.title, colors: colors)
            header.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(header)
            header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

            for scored in section.items {
                let index = rows.count
                rows.append(scored)
                let row = PaletteRowView()
                row.translatesAutoresizingMaskIntoConstraints = false
                row.onClick = { [weak self] in
                    self?.selection = index
                    self?.commit()
                }
                row.onHover = { [weak self] in self?.hover(index) }
                if case .switchTab(let controller, let tabId) = scored.item.command {
                    row.onClose = { [weak self] in
                        self?.selection = index
                        self?.onCloseTab?(controller, tabId)
                    }
                }
                // After the callbacks: `apply` decides whether the row can show
                // a ✕ by asking whether it has an `onClose`.
                row.apply(scored, colors: colors)
                stack.addArrangedSubview(row)
                NSLayoutConstraint.activate([
                    row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -10),
                    row.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 5),
                ])
                rowViews.append(row)
            }
        }

        if rows.isEmpty {
            let empty = NSTextField(labelWithString: "No matches")
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = colors.dim
            empty.translatesAutoresizingMaskIntoConstraints = false
            let box = NSView()
            box.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(empty)
            stack.addArrangedSubview(box)
            NSLayoutConstraint.activate([
                box.widthAnchor.constraint(equalTo: stack.widthAnchor),
                box.heightAnchor.constraint(equalToConstant: 66),
                empty.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                empty.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            ])
        }

        selection = min(selection, max(0, rows.count - 1))
        updateChrome()

        // Lay out *before* touching the selection. These row views were created
        // a few lines ago and still have zero frames; `scrollToVisible` on a
        // zero frame silently does nothing, so the clip view keeps whatever
        // offset the previous list left it at and the selected row ends up
        // parked off-screen — which is why only the hovered row ever appeared
        // to be selected.
        layoutSubtreeIfNeeded()
        listHeight.constant = min(Self.maxListHeight, max(66, stack.fittingSize.height))
        layoutSubtreeIfNeeded()

        // A rebuilt list starts at the top: the scroll view has no idea its
        // contents were replaced, and an offset measured against the old rows
        // means nothing for the new ones.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)

        paintSelection()
    }

    private func updateChrome() {
        crumb.isHidden = stage != .themes
        crumb.stringValue = "Theme"
        scopeChip.stringValue = "⇥ \(parsedQuery.scope.title)"
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.font: NSFont.systemFont(ofSize: 18),
                         .foregroundColor: colors.dim])
    }

    /// Hands the selection back to the keyboard until the pointer next moves.
    ///
    /// Every re-render builds fresh row views under a pointer that hasn't
    /// gone anywhere, and every scroll slides existing ones beneath it. Both
    /// deliver `mouseEntered`, which is indistinguishable from a real hover
    /// unless the anchor is reset each time the keyboard acts — without this,
    /// typing a letter throws the selection onto whichever row happens to land
    /// under the mouse, and the arrows appear not to work.
    private func disarmHover() {
        hoverAnchor = NSEvent.mouseLocation
        hoverArmed = false
    }

    /// Hover, gated on the pointer having actually moved since then.
    private func hover(_ index: Int) {
        if !hoverArmed {
            let now = NSEvent.mouseLocation
            guard abs(now.x - hoverAnchor.x) > 2 || abs(now.y - hoverAnchor.y) > 2
            else { return }
            hoverArmed = true
        }
        select(index)
    }

    private var placeholder: String {
        stage == .themes ? "Pick a theme…" : "Switch to a tab or run an action…"
    }

    private func select(_ index: Int) {
        guard index >= 0, index < rows.count, index != selection else { return }
        selection = index
        paintSelection()
    }

    private func paintSelection() {
        for (i, view) in rowViews.enumerated() {
            view.isSelected = (i == selection)
        }
        guard selection < rowViews.count else { return }
        let target = rowViews[selection]
        // Converted rather than taken raw: `frame` is in the stack's space, and
        // only coincides with the document's while the stack sits flush at its
        // origin. Converting says what is meant and survives that changing.
        //
        // The inset brings the header above a section's first row into view
        // with it, so the selection never sits flush against the top edge with
        // its section label cut off.
        var rect = target.convert(target.bounds, to: document)
        if selection == 0 { rect = rect.insetBy(dx: 0, dy: -26) }
        document.scrollToVisible(rect)
    }

    private func move(by delta: Int) {
        guard !rows.isEmpty else { return }
        disarmHover()
        selection = (selection + delta + rows.count) % rows.count
        paintSelection()
    }

    // MARK: running

    private func commit() {
        guard selection < rows.count else { return }
        let item = rows[selection].item
        if case .drillIntoThemes = item.command {
            stage = .themes
            field.stringValue = ""
            selection = 0
            render()
            return
        }
        onRun?(item.command)
    }

    private func closeSelectedTab() {
        guard selection < rows.count,
              case .switchTab(let controller, let tabId) = rows[selection].item.command
        else { return }
        onCloseTab?(controller, tabId)
    }

    private func dismiss() {
        dismissing = true
        onDismiss?()
    }

    // MARK: theming

    @objc private func themeDidChange() {
        applyColors()
        render()
    }

    private func applyColors() {
        colors = PaletteColors.current(for: themeProvider?() ?? ThemeStore.currentTheme)

        // Everything AppKit draws for us — the insertion point, the field
        // editor's selection, the focus ring, the overlay scroller, the close
        // button's pressed state — takes its cue from the effective appearance,
        // not from our colours. Without this a dark theme under a light macOS
        // gets a black caret and a light scroller on a dark panel.
        content.appearance = NSAppearance(named: colors.isDark ? .darkAqua : .aqua)
        scroll.scrollerKnobStyle = colors.isDark ? .light : .dark
        magnifier.contentTintColor = colors.dim
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.font: NSFont.systemFont(ofSize: 18),
                         .foregroundColor: colors.dim])
        content.layer?.backgroundColor = colors.panel.cgColor
        content.layer?.borderColor = colors.border.cgColor

        // Elevation, not decoration: this is what makes the hub read as an
        // object resting above the terminal rather than a rectangle drawn on
        // it. The offset is positive-downward because the surface it sits in
        // (TerminalSurface) is flipped.
        layer?.shadowColor = colors.shadow.cgColor
        layer?.shadowOpacity = colors.isDark ? 0.58 : 0.34
        layer?.shadowRadius = 26
        layer?.shadowOffset = CGSize(width: 0, height: 12)
        fieldDivider.layer?.backgroundColor = colors.border.cgColor
        footerDivider.layer?.backgroundColor = colors.border.cgColor
        field.textColor = colors.ink
        footer.textColor = colors.dim
        crumb.apply(colors)
        scopeChip.apply(colors)
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        selection = 0
        render()
    }

    /// Clicking into the terminal, or the window losing key, ends editing —
    /// and a hub that stays up with no focus is a hub you can't dismiss with
    /// Esc. Spotlight behaves the same way.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard !dismissing else { return }
        dismiss()
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        // Both arrows and ⌃N / ⌃P arrive here: AppKit's standard key bindings
        // already map the readline pair onto these selectors.
        case #selector(NSResponder.moveDown(_:)):
            move(by: 1); return true
        case #selector(NSResponder.moveUp(_:)):
            move(by: -1); return true
        case #selector(NSResponder.insertNewline(_:)):
            commit(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss(); return true
        case #selector(NSResponder.insertTab(_:)):
            cycleScope(backwards: false); return true
        case #selector(NSResponder.insertBacktab(_:)):
            cycleScope(backwards: true); return true
        // ⌘⌫ in a text field is "delete to beginning of line". On a tab row it
        // closes that tab instead and leaves the hub up; anywhere else it does
        // what the text field would.
        case #selector(NSResponder.deleteToBeginningOfLine(_:)):
            if selection < rows.count, case .switchTab = rows[selection].item.command {
                closeSelectedTab()
                return true
            }
            return false
        case #selector(NSResponder.deleteBackward(_:)):
            guard field.stringValue.isEmpty else { return false }
            if stage != .root { popStage(); return true }
            if scope != .all { scope = .all; selection = 0; render(); return true }
            return false
        default:
            return false
        }
    }

    private func stripSigil() {
        if field.stringValue.hasPrefix(">") { field.stringValue.removeFirst() }
    }
}

/// A small rounded label — the drill-in breadcrumb and the scope indicator.
///
/// A container around a label rather than a padded `NSTextField`. Growing a
/// text field's `intrinsicContentSize` does not move the text: the cell draws
/// against its baseline in the top of the enlarged frame, so the label sits
/// high inside its own rounded box and the chip reads as misaligned against
/// the search field beside it. Centring a real subview is the fix.
final class PaletteChip: NSView {
    private let label = NSTextField(labelWithString: "")

    var stringValue: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var onClick: (() -> Void)?

    /// Consumed whether or not anyone is listening. An unhandled press here
    /// falls through to the terminal below, which takes first responder and
    /// ends the hub's field editor — so clicking a chip would close the hub
    /// instead of doing its job.
    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = pressed
        pressed = false
        guard wasPressed,
              bounds.contains(convert(event.locationInWindow, from: nil))
        else { return }
        onClick?()
    }

    private var pressed = false

    func apply(_ colors: PaletteColors) {
        label.textColor = colors.dim
        layer?.backgroundColor = colors.elevated.cgColor
        layer?.borderColor = colors.border.cgColor
    }
}

/// Scroll content grows downward from the top, the way a list reads.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The hub's own surface, which absorbs any press that nothing else claimed.
///
/// Unhandled mouse events walk up the responder chain, and past this view the
/// chain reaches the terminal — which takes first responder, ends the field
/// editor and dismisses the hub. Without this, clicking the hub's padding, its
/// footer, or the gap beside a row would close it.
private final class ClickSwallowingView: NSView {
    override func mouseDown(with event: NSEvent) {}
}
