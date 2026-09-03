import SwiftUI

/// Settings window: a System Settings-style sidebar of categories on the left,
/// the selected pane on the right, and a search field over the sidebar that
/// replaces the categories with matching controls.
struct SettingsView: View {
    @ObservedObject private var store = ThemeStore.shared
    @State private var selection: SettingsCategory? = .appearance

    /// Focus lives here rather than in each pane because Tab has to be caught
    /// even when nothing in the pane is focused — which is how the window
    /// opens. `onKeyPress` only fires for the focused view and its ancestors,
    /// so the handler has to sit above both the sidebar and the detail pane.
    @FocusState private var focus: SettingsField?

    /// Flipped by the first Tab. See `settingsKeyboardActive`.
    @State private var keyboardActive = false

    @State private var query = ""
    /// The control a search result asked for, held until its pane has been
    /// laid out. Focus set on a view that doesn't exist yet is dropped.
    @State private var pendingFocus: SettingsField?

    private var results: [SettingsEntry] { SettingsIndex.search(query) }

    var body: some View {
        NavigationSplitView {
            if query.isEmpty {
                List(SettingsCategory.allCases, selection: $selection) { category in
                    Label(category.title, systemImage: category.systemImage)
                        .tag(category)
                }
                .navigationSplitViewColumnWidth(min: 160, ideal: 175, max: 220)
                // Named so ⇧Tab off the first control can hand the arrow keys
                // back to the category list.
                .focused($focus, equals: .sidebar)
            } else {
                resultsList
                    .navigationSplitViewColumnWidth(min: 160, ideal: 175, max: 220)
            }
        } detail: {
            detail(for: selection ?? .appearance)
                .navigationTitle((selection ?? .appearance).title)
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search settings")
        .onKeyPress(keys: [.tab]) { press in
            let delta = press.modifiers.contains(.shift) ? -1 : 1
            let next = nextFocus(after: focus, in: stops, by: delta)
            if keyboardActive {
                focus = next
            } else {
                // First Tab: the controls only become focusable as a result of
                // this same state change, so the assignment has to wait for the
                // next pass — focus set on a view that isn't focusable yet is
                // dropped.
                keyboardActive = true
                DispatchQueue.main.async { focus = next }
            }
            return .handled
        }
        // A new pane opens the way the window did: inert, nothing selected,
        // arrows still on the list — unless a search result asked for a
        // particular control, in which case that is the whole point of having
        // switched panes.
        .onChange(of: selection) { _, _ in
            if pendingFocus != nil {
                applyPendingFocus()
            } else {
                keyboardActive = false
                focus = .sidebar
            }
        }
        // Holding focus on the list is what keeps ↑/↓ changing section, and is
        // also what lets the Tab handler above see the key at all — onKeyPress
        // fires for the focused view and its ancestors, nothing else.
        .onAppear { focus = .sidebar }
        .environment(\.settingsKeyboardActive, keyboardActive)
    }

    // MARK: search results

    @ViewBuilder
    private var resultsList: some View {
        if results.isEmpty {
            VStack(spacing: 6) {
                Text("No settings found")
                    .foregroundStyle(.secondary)
                Text("Try “font”, “scrollback”, or “bell”.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            List(results) { entry in
                Button { open(entry) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.label)
                            .lineLimit(2)
                        // Which pane it lives in, so a result is somewhere you
                        // can go back to without searching again.
                        Label(entry.category.title, systemImage: entry.category.systemImage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Opens the pane a result lives in and puts focus on the control, which
    /// is what makes a result findable on the page once you get there — the
    /// focus ring is the "here it is".
    private func open(_ entry: SettingsEntry) {
        pendingFocus = entry.field
        if selection == entry.category {
            // Same pane: `onChange` won't fire, so apply it directly.
            applyPendingFocus()
        } else {
            selection = entry.category
        }
    }

    private func applyPendingFocus() {
        guard let field = pendingFocus else { return }
        pendingFocus = nil
        // The controls are only focusable once this is on, and a focus set in
        // the same pass is dropped — same reason the first Tab defers.
        keyboardActive = true
        DispatchQueue.main.async { focus = field }
    }

    /// The category list, then the selected pane's controls in layout order.
    ///
    /// Taken from `SettingsIndex`, which is also what search reads — one list,
    /// so a control cannot be Tab-reachable but unsearchable or the reverse.
    private var stops: [SettingsField] {
        let category = selection ?? .appearance
        var fields = SettingsIndex.fields(in: category)
        // The two dependent notification toggles are disabled when
        // notifications are off, so they drop out of the Tab order rather than
        // being focus stops that do nothing.
        if category == .notifications, !store.settings.notificationsEnabled {
            fields = [.notificationsEnabled]
        }
        return [.sidebar] + fields
    }

    @ViewBuilder
    private func detail(for category: SettingsCategory) -> some View {
        switch category {
        case .appearance:    AppearancePane(focus: $focus)
        case .profiles:      ProfilesPane(focus: $focus)
        case .triggers:      TriggersPane(focus: $focus)
        case .general:       GeneralPane(focus: $focus)
        case .notifications: NotificationsPane(focus: $focus)
        }
    }
}
