import SwiftUI

struct GeneralPane: View {
    @ObservedObject private var store = ThemeStore.shared
    @FocusState.Binding var focus: SettingsField?

    static let fieldOrder: [SettingsField] = [.warnOnClose]

    init(focus: FocusState<SettingsField?>.Binding) {
        self._focus = focus
    }

    var body: some View {
        Form {
            Section("Sessions") {
                Toggle("Warn before closing a tab with a running process",
                       isOn: $store.settings.warnOnCloseWithRunningProcess)
                    .focusableControl(.warnOnClose, focus: $focus, onActivate: {
                        store.settings.warnOnCloseWithRunningProcess.toggle()
                    })
            }
        }
        .formStyle(.grouped)
    }
}
