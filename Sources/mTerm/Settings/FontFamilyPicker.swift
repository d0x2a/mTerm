import AppKit
import SwiftUI

extension FontCatalog.Entry {
    /// The entry's own typeface, for setting a font's name in itself.
    /// SF Mono carries no PostScript name — it's reached through
    /// `monospacedSystemFont` — so it can't be looked up by name.
    func previewFont(size: CGFloat) -> NSFont {
        if postScriptName.isEmpty {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return NSFont(name: postScriptName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// Font family chooser: a stock pop-up button that opens a searchable list,
/// each row set in the font it names.
///
/// Built from AppKit rather than SwiftUI on purpose. A visible search field
/// can't live inside an `NSMenu` — there's no public API for it — so the
/// dropdown has to be a popover; and a popover of SwiftUI controls next to
/// the pane's native pop-up buttons reads as foreign however carefully it's
/// styled. Using a real `NSSearchField` and a real `NSTableView` means the
/// search field, the row highlight and the keyboard handling are the system's,
/// not an imitation of them.
struct FontFamilyPicker: NSViewRepresentable {
    @Binding var selection: String
    /// Curated fonts, shown first under "Recommended".
    let recommended: [FontCatalog.Entry]
    /// Everything else installed that's monospaced, under "Other".
    let others: [FontCatalog.Entry]

    func makeNSView(context: Context) -> FontPopUpButton {
        let button = FontPopUpButton(frame: .zero, pullsDown: false)
        button.bezelStyle = .rounded
        // Hug the widest name rather than filling the row, so this sits the
        // same way as the theme pop-ups directly above it.
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.onPress = { [weak button] in
            guard let button else { return }
            context.coordinator.present(from: button)
        }
        return button
    }

    func updateNSView(_ button: FontPopUpButton, context: Context) {
        context.coordinator.parent = self

        applyTitle(to: button)
    }

    /// The closed control shows the current font in its own face. It holds
    /// exactly one menu item: the menu is never dropped, the popover is.
    func applyTitle(to button: FontPopUpButton) {
        let menu = NSMenu()
        let item = NSMenuItem(title: selection, action: nil, keyEquivalent: "")
        if let entry = (recommended + others).first(where: { $0.displayName == selection }) {
            item.attributedTitle = Self.buttonTitle(
                selection, font: entry.previewFont(size: NSFont.systemFontSize))
        } else {
            // Chosen font has been uninstalled. Keep showing its name rather
            // than going blank — it's still what the terminal returns to if
            // the font comes back — but say so.
            item.attributedTitle = Self.buttonTitle(
                "\(selection) (not installed)",
                font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                color: .secondaryLabelColor)
        }
        menu.addItem(item)
        button.menu = menu
        button.selectItem(at: 0)
    }

    /// The closed button's title, drawn in the font it names but laid out at
    /// a fixed line height.
    ///
    /// Without the pinned height the control's `firstBaselineOffsetFromTop`
    /// follows each family's metrics — 15.5 pt for Courier against 16.5 pt
    /// for most — and a Form row aligns on baselines, so simply choosing a
    /// font nudged the whole row up or down. The button's *intrinsic* height
    /// is a constant 24 pt either way, which is why this looked like it
    /// couldn't be the control.
    private static func buttonTitle(_ string: String,
                                    font: NSFont,
                                    color: NSColor? = nil) -> NSAttributedString {
        let reference = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let line = ceil(reference.ascender - reference.descender)
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = line
        style.maximumLineHeight = line
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style]
        if let color { attributes[.foregroundColor] = color }
        return NSAttributedString(string: string, attributes: attributes)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: FontFamilyPicker
        private var popover: NSPopover?

        init(_ parent: FontFamilyPicker) { self.parent = parent }

        func present(from button: NSView) {
            if let open = popover, open.isShown { open.close(); popover = nil; return }
            let controller = FontListViewController(
                recommended: parent.recommended,
                others: parent.others,
                selection: parent.selection,
                onPick: { [weak self] name in
                    self?.parent.selection = name
                    self?.popover?.close()
                    self?.popover = nil
                },
                onCancel: { [weak self] in
                    self?.popover?.close()
                    self?.popover = nil
                })
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = controller
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            self.popover = popover
        }
    }
}

/// Pop-up button that opens a popover instead of dropping its menu. Subclassed
/// rather than assembled from an `NSButton` so the bezel, the chevrons and the
/// metrics are the system's own, identical to the pop-ups above it.
final class FontPopUpButton: NSPopUpButton {
    var onPress: (() -> Void)?

    override func mouseDown(with event: NSEvent) { onPress?() }

    override func keyDown(with event: NSEvent) {
        // Space and Return open it, as they would a real pop-up.
        if event.keyCode == 49 || event.keyCode == 36 { onPress?(); return }
        super.keyDown(with: event)
    }
}

/// Search field over a table of fonts, shown inside the pop-up's popover.
final class FontListViewController: NSViewController,
                                    NSTableViewDataSource, NSTableViewDelegate,
                                    NSSearchFieldDelegate {
    /// A visible line: either a section heading or a selectable font.
    private enum Row {
        case header(String)
        case font(FontCatalog.Entry)
    }

    private let recommended: [FontCatalog.Entry]
    private let others: [FontCatalog.Entry]
    private let selection: String
    private let onPick: (String) -> Void
    private let onCancel: () -> Void

    private var rows: [Row]
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    private static let rowHeight: CGFloat = 24
    private static let headerHeight: CGFloat = 22
    private static let width: CGFloat = 260
    private static let maxListHeight: CGFloat = 320

    init(recommended: [FontCatalog.Entry], others: [FontCatalog.Entry],
         selection: String,
         onPick: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.recommended = recommended
        self.others = others
        self.selection = selection
        self.onPick = onPick
        self.onCancel = onCancel
        self.rows = Self.rows(recommended: recommended, others: others, query: "")
        super.init(nibName: nil, bundle: nil)
    }

    /// Splits the matches into sections. A heading is only drawn when both
    /// sections have something in them — filtering down to one section makes
    /// its heading redundant, and a lone header over a short list reads worse
    /// than no header at all.
    private static func rows(recommended: [FontCatalog.Entry],
                             others: [FontCatalog.Entry],
                             query: String) -> [Row] {
        func matching(_ list: [FontCatalog.Entry]) -> [FontCatalog.Entry] {
            query.isEmpty
                ? list
                : list.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
        }
        let top = matching(recommended), rest = matching(others)
        let headings = !top.isEmpty && !rest.isEmpty
        var out: [Row] = []
        if !top.isEmpty {
            if headings { out.append(.header("Recommended")) }
            out.append(contentsOf: top.map(Row.font))
        }
        if !rest.isEmpty {
            if headings { out.append(.header("Other")) }
            out.append(contentsOf: rest.map(Row.font))
        }
        return out
    }

    private func entry(at row: Int) -> FontCatalog.Entry? {
        guard row >= 0, row < rows.count, case .font(let e) = rows[row] else { return nil }
        return e
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let container = NSView()

        searchField.placeholderString = "Search fonts"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.focusRingType = .none
        container.addSubview(searchField)

        let column = NSTableColumn(identifier: .init("font"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.style = .inset
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)          // single click commits

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        let listHeight = min(max(contentHeight(), Self.rowHeight) + 8, Self.maxListHeight)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 7),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 7),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -7),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            scrollView.heightAnchor.constraint(equalToConstant: listHeight),
        ])
        container.frame = NSRect(x: 0, y: 0, width: Self.width, height: 0)
        self.view = container
        preferredContentSize = NSSize(width: Self.width, height: listHeight + 44)
        selectRow(forName: selection)
    }

    private func contentHeight() -> CGFloat {
        rows.reduce(0) { total, row in
            if case .header = row { return total + Self.headerHeight }
            return total + Self.rowHeight
        }
    }

    /// Focus is taken here rather than straight after `NSPopover.show` — at
    /// that point the popover's window may not exist yet, so the
    /// `makeFirstResponder` lands on nothing and the first keystrokes are
    /// dropped. `viewDidAppear` runs once the window is real.
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    private func selectRow(forName name: String) {
        guard let idx = rows.firstIndex(where: {
            if case .font(let e) = $0 { return e.displayName == name }
            return false
        }) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes([idx], byExtendingSelection: false)
        tableView.scrollRowToVisible(idx)
    }

    private func selectFirstFont() {
        guard let idx = rows.firstIndex(where: { if case .font = $0 { return true }; return false })
        else { tableView.deselectAll(nil); return }
        tableView.selectRowIndexes([idx], byExtendingSelection: false)
        tableView.scrollRowToVisible(idx)
    }

    @objc private func rowClicked() {
        guard let e = entry(at: tableView.clickedRow) else { return }
        onPick(e.displayName)
    }

    private func commitSelection() {
        guard let e = entry(at: tableView.selectedRow) else { return }
        onPick(e.displayName)
    }

    /// Steps to the next selectable row, stepping over section headings so
    /// the arrow keys never land the highlight on one.
    private func move(by delta: Int) {
        var next = tableView.selectedRow
        if next < 0 { next = delta > 0 ? -1 : rows.count }
        var candidate = next + delta
        while candidate >= 0 && candidate < rows.count {
            if entry(at: candidate) != nil {
                tableView.selectRowIndexes([candidate], byExtendingSelection: false)
                tableView.scrollRowToVisible(candidate)
                return
            }
            candidate += delta
        }
    }

    // MARK: search

    func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        rows = Self.rows(recommended: recommended, others: others, query: query)
        tableView.reloadData()
        // Keep the current font selected while it still matches; otherwise put
        // the highlight on the first hit so Return picks the obvious thing.
        if rows.contains(where: {
            if case .font(let e) = $0 { return e.displayName == selection }
            return false
        }) {
            selectRow(forName: selection)
        } else {
            selectFirstFont()
        }
    }

    /// Arrow keys drive the table while the caret stays in the search field,
    /// so a font can be found and chosen without leaving the keyboard.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):    move(by: 1);  return true
        case #selector(NSResponder.moveUp(_:)):      move(by: -1); return true
        case #selector(NSResponder.insertNewline(_:)): commitSelection(); return true
        case #selector(NSResponder.cancelOperation(_:)): onCancel(); return true
        default: return false
        }
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        entry(at: row) != nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return Self.headerHeight }
        return Self.rowHeight
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let id = NSUserInterfaceItemIdentifier("headerCell")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? SectionHeaderView)
                ?? SectionHeaderView(identifier: id)
            cell.configure(title: title)
            return cell
        case .font(let entry):
            let id = NSUserInterfaceItemIdentifier("fontCell")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? FontCellView)
                ?? FontCellView(identifier: id)
            cell.configure(name: entry.displayName, font: entry.previewFont(size: 13))
            return cell
        }
    }
}

/// "Recommended" / "Other" heading. A plain label rather than the table's own
/// group-row styling, which is built for source lists and draws far heavier
/// than a short popover wants.
private final class SectionHeaderView: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(title: String) {
        textField?.stringValue = title.uppercased()
    }
}

/// Row view that re-tints its label when the row is highlighted. An attributed
/// string carries its own colour, so unlike a plain `stringValue` it won't be
/// inverted for us — without this the name stays dark on the blue selection.
private final class FontCellView: NSTableCellView {
    private var name = ""
    private var previewFont = NSFont.systemFont(ofSize: 13)

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(name: String, font: NSFont) {
        self.name = name
        self.previewFont = font
        applyText()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyText() }
    }

    private func applyText() {
        let color: NSColor = backgroundStyle == .emphasized
            ? .alternateSelectedControlTextColor
            : .labelColor
        textField?.attributedStringValue = NSAttributedString(
            string: name, attributes: [.font: previewFont, .foregroundColor: color])
    }
}
