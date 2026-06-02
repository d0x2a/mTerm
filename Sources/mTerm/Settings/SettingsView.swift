import SwiftUI

/// Settings window: a System Settings-style sidebar of categories on the left,
/// the selected pane on the right.
struct SettingsView: View {
    private enum Category: String, CaseIterable, Identifiable {
        case appearance, general, notifications

        var id: String { rawValue }

        var title: String {
            switch self {
            case .appearance:    return "Appearance"
            case .general:       return "General"
            case .notifications: return "Notifications"
            }
        }

        var systemImage: String {
            switch self {
            case .appearance:    return "paintbrush"
            case .general:       return "gearshape"
            case .notifications: return "bell"
            }
        }
    }

    @State private var selection: Category? = .appearance

    var body: some View {
        NavigationSplitView {
            List(Category.allCases, selection: $selection) { category in
                Label(category.title, systemImage: category.systemImage)
                    .tag(category)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 175, max: 220)
        } detail: {
            detail(for: selection ?? .appearance)
                .navigationTitle((selection ?? .appearance).title)
        }
    }

    @ViewBuilder
    private func detail(for category: Category) -> some View {
        switch category {
        case .appearance:    AppearancePane()
        case .general:       GeneralPane()
        case .notifications: NotificationsPane()
        }
    }
}
