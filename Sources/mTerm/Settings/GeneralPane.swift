import SwiftUI

struct GeneralPane: View {
    @ObservedObject private var store = ThemeStore.shared

    var body: some View {
        Form {
            Section("Sessions") {
                Toggle("Warn before closing a tab with a running process",
                       isOn: $store.settings.warnOnCloseWithRunningProcess)
            }
        }
        .formStyle(.grouped)
    }
}
