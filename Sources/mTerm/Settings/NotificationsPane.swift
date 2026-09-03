import SwiftUI

struct NotificationsPane: View {
    @ObservedObject private var store = ThemeStore.shared
    @FocusState.Binding var focus: SettingsField?

    init(focus: FocusState<SettingsField?>.Binding) {
        self._focus = focus
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable notifications",
                       isOn: $store.settings.notificationsEnabled)
                    .onChange(of: store.settings.notificationsEnabled) { _, enabled in
                        if enabled { NotificationManager.shared.requestAuthorizationIfNeeded() }
                    }
                    .focusableControl(.notificationsEnabled, focus: $focus, onActivate: {
                        store.settings.notificationsEnabled.toggle()
                    })
                Toggle("Notify on terminal bell",
                       isOn: $store.settings.notifyOnBell)
                    .disabled(!store.settings.notificationsEnabled)
                    .focusableControl(.notifyOnBell, focus: $focus, onActivate: {
                        guard store.settings.notificationsEnabled else { return }
                        store.settings.notifyOnBell.toggle()
                    })
                Toggle("Only when the tab isn’t focused",
                       isOn: $store.settings.notifyOnlyWhenUnfocused)
                    .disabled(!store.settings.notificationsEnabled)
                    .focusableControl(.notifyOnlyWhenUnfocused, focus: $focus, onActivate: {
                        guard store.settings.notificationsEnabled else { return }
                        store.settings.notifyOnlyWhenUnfocused.toggle()
                    })
            } footer: {
                Text("Posts a macOS notification when a program rings the bell or "
                     + "sends a notification escape — e.g. Claude Code waiting for your input.")
            }
        }
        .formStyle(.grouped)
    }
}
