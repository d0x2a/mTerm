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
    let entries: [FontCatalog.Entry]

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

        // The closed control shows the current font in its own face. It holds
        // exactly one item: the menu is never dropped, the popover is.
        let menu = NSMenu()
        let item = NSMenuItem(title: selection, action: nil, keyEquivalent: "")
        if let entry = entries.first(where: { $0.displayName == selection }) {
            item.attributedTitle = NSAttributedString(
                string: selection,
                attributes: [.font: entry.previewFont(size: NSFont.systemFontSize)])
        } else {
            // Chosen font has been uninstalled. Keep showing its name rather
            // than going blank — it's still what the terminal returns to if
            // the font comes back — but say so.
            item.attributedTitle = NSAttributedString(
                string: "\(selection) (not installed)",
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                             .foregroundColor: NSColor.secondaryLabelColor])
        }
        menu.addItem(item)
        button.menu = menu
        button.selectItem(at: 0)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: FontFamilyPicker
        private var popover: NSPopover?

        init(_ parent: FontFamilyPicker) { self.parent = parent }

        func present(from button: NSView) {
            if let open = popover, open.isShown { open.close(); popover = nil; return }
            let controller = FontListViewController(
                entries: parent.entries,
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
            controller.focusSearchField()
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
    private let entries: [FontCatalog.Entry]
    private let selection: String
    private let onPick: (String) -> Void
    private let onCancel: () -> Void

    private var filtered: [FontCatalog.Entry]
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    private static let rowHeight: CGFloat = 24
    private static let width: CGFloat = 260
    private static let maxListHeight: CGFloat = 320

    init(entries: [FontCatalog.Entry], selection: String,
         onPick: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.entries = entries
        self.selection = selection
        self.filtered = entries
        self.onPick = onPick
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
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

        let listHeight = min(CGFloat(max(filtered.count, 1)) * Self.rowHeight + 8,
                             Self.maxListHeight)
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

    func focusSearchField() {
        view.window?.makeFirstResponder(searchField)
    }

    private func selectRow(forName name: String) {
        guard let idx = filtered.firstIndex(where: { $0.displayName == name }) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes([idx], byExtendingSelection: false)
        tableView.scrollRowToVisible(idx)
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < filtered.count else { return }
        onPick(filtered[row].displayName)
    }

    private func commitSelection() {
        let row = tableView.selectedRow
        guard row >= 0, row < filtered.count else { return }
        onPick(filtered[row].displayName)
    }

    private func move(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let current = tableView.selectedRow
        let next = current < 0
            ? (delta > 0 ? 0 : filtered.count - 1)
            : min(max(current + delta, 0), filtered.count - 1)
        tableView.selectRowIndexes([next], byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    // MARK: search

    func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        filtered = query.isEmpty
            ? entries
            : entries.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
        tableView.reloadData()
        // Keep the current font selected while it still matches; otherwise put
        // the highlight on the first hit so Return picks the obvious thing.
        if filtered.contains(where: { $0.displayName == selection }) {
            selectRow(forName: selection)
        } else if !filtered.isEmpty {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
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

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("fontCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? FontCellView)
            ?? FontCellView(identifier: id)
        cell.configure(name: filtered[row].displayName,
                       font: filtered[row].previewFont(size: 13))
        return cell
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
