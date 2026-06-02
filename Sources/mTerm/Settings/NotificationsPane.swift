import SwiftUI

struct NotificationsPane: View {
    @ObservedObject private var store = ThemeStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Enable notifications",
                       isOn: $store.settings.notificationsEnabled)
                    .onChange(of: store.settings.notificationsEnabled) { _, enabled in
                        if enabled { NotificationManager.shared.requestAuthorizationIfNeeded() }
                    }
                Toggle("Notify on terminal bell",
                       isOn: $store.settings.notifyOnBell)
                    .disabled(!store.settings.notificationsEnabled)
                Toggle("Only when the tab isn’t focused",
                       isOn: $store.settings.notifyOnlyWhenUnfocused)
                    .disabled(!store.settings.notificationsEnabled)
            } footer: {
                Text("Posts a macOS notification when a program rings the bell or "
                     + "sends a notification escape — e.g. Claude Code waiting for your input.")
            }
        }
        .formStyle(.grouped)
    }
}
