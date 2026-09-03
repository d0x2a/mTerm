import SwiftUI

/// Settings window: a System Settings-style sidebar of categories on the left,
/// the selected pane on the right.
struct SettingsView: View {
    private enum Category: String, CaseIterable, Identifiable {
        case appearance, profiles, triggers, general, notifications

        var id: String { rawValue }

        var title: String {
            switch self {
            case .appearance:    return "Appearance"
            case .profiles:      return "Profiles"
            case .triggers:      return "Triggers"
            case .general:       return "General"
            case .notifications: return "Notifications"
            }
        }

        var systemImage: String {
            switch self {
            case .appearance:    return "paintbrush"
            case .profiles:      return "person.crop.rectangle.stack"
            case .triggers:      return "bolt.horizontal"
            case .general:       return "gearshape"
            case .notifications: return "bell"
            }
        }
    }

    @ObservedObject private var store = ThemeStore.shared
    @State private var selection: Category? = .appearance

    /// Focus lives here rather than in each pane because Tab has to be caught
    /// even when nothing in the pane is focused — which is how the window
    /// opens. `onKeyPress` only fires for the focused view and its ancestors,
    /// so the handler has to sit above both the sidebar and the detail pane.
    @FocusState private var focus: SettingsField?

    /// Flipped by the first Tab. See `settingsKeyboardActive`.
    @State private var keyboardActive = false

    var body: some View {
        NavigationSplitView {
            List(Category.allCases, selection: $selection) { category in
                Label(category.title, systemImage: category.systemImage)
                    .tag(category)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 175, max: 220)
            // Named so ⇧Tab off the first control can hand the arrow keys back
            // to the category list.
            .focused($focus, equals: .sidebar)
        } detail: {
            detail(for: selection ?? .appearance)
                .navigationTitle((selection ?? .appearance).title)
        }
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
        // arrows still on the list.
        .onChange(of: selection) { _, _ in
            keyboardActive = false
            focus = .sidebar
        }
        // Holding focus on the list is what keeps ↑/↓ changing section, and is
        // also what lets the Tab handler above see the key at all — onKeyPress
        // fires for the focused view and its ancestors, nothing else.
        .onAppear { focus = .sidebar }
        .environment(\.settingsKeyboardActive, keyboardActive)
    }

    /// The category list, then the selected pane's controls in layout order.
    /// Each pane owns its own order so the list can't drift from the layout.
    private var stops: [SettingsField] {
        let fields: [SettingsField]
        switch selection ?? .appearance {
        case .appearance:
            fields = AppearancePane.fieldOrder
        case .profiles:
            fields = ProfilesPane.fieldOrder
        case .triggers:
            fields = TriggersPane.fieldOrder
        case .general:
            fields = GeneralPane.fieldOrder
        case .notifications:
            fields = NotificationsPane.fieldOrder(
                notificationsEnabled: store.settings.notificationsEnabled)
        }
        return [.sidebar] + fields
    }

    @ViewBuilder
    private func detail(for category: Category) -> some View {
        switch category {
        case .appearance:    AppearancePane(focus: $focus)
        case .profiles:      ProfilesPane(focus: $focus)
        case .triggers:      TriggersPane(focus: $focus)
        case .general:       GeneralPane(focus: $focus)
        case .notifications: NotificationsPane(focus: $focus)
        }
    }
}
