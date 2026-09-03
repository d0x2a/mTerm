import SwiftUI

struct GeneralPane: View {
    @ObservedObject private var store = ThemeStore.shared
    @FocusState.Binding var focus: SettingsField?

    init(focus: FocusState<SettingsField?>.Binding) {
        self._focus = focus
    }

    /// The offered depths, plus whatever is currently set if someone put a
    /// value of their own in settings.json — the picker shouldn't silently
    /// round a hand-edited 7,500 up to 10,000 the first time it is shown.
    private var scrollbackChoices: [Int] {
        let current = store.settings.scrollbackLines
        var choices = AppSettings.scrollbackChoices
        if !choices.contains(current) {
            choices.append(current)
            choices.sort()
        }
        return choices
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

            Section("Scrollback") {
                Picker("Lines kept per tab", selection: $store.settings.scrollbackLines) {
                    ForEach(scrollbackChoices, id: \.self) { lines in
                        Text(lines.formatted(.number.grouping(.automatic))).tag(lines)
                    }
                }
                .focusableControl(.scrollbackLines, focus: $focus) { direction in
                    stepSelection(&store.settings.scrollbackLines,
                                  in: scrollbackChoices, by: direction)
                }
                Text(scrollbackNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shell Integration") {
                Toggle("Track the prompt and working directory",
                       isOn: $store.settings.shellIntegrationEnabled)
                    .focusableControl(.shellIntegration, focus: $focus, onActivate: {
                        store.settings.shellIntegrationEnabled.toggle()
                    })
                Text("Gives zsh, bash and fish mTerm's OSC 133 and OSC 7 hooks, which is "
                     + "what the prompt markers in the gutter, ⌘↑ / ⌘↓ jump-to-prompt and "
                     + "relative-path links are built on. Nothing is written to your own "
                     + "rc files — each shell gets a wrapper in front of them that sources "
                     + "your real startup files first. Off, a shell starts exactly as it "
                     + "would from any other terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Both halves of the answer people want: what it costs, and when it takes
    /// effect. The ring is allocated once when a buffer is built, so changing
    /// the depth can't reach a tab that already exists.
    private var scrollbackNote: String {
        // ~4.2 MB per 1,000 rows at 200 columns, measured — see
        // docs/BENCHMARKS.md. Rows are 16 bytes a column plus per-row array
        // overhead, so this is deliberately the measured figure rather than
        // the arithmetic one.
        let mb = Double(store.settings.scrollbackLines) / 1000 * 4.2
        return String(format: "About %.0f MB per tab at 200 columns. ", mb)
            + "Applies to tabs opened from now on — a tab's history is sized when it starts."
    }
}
