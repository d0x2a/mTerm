import AppKit
import SwiftUI

/// Profiles: the list on top, an editor for the selected one below.
///
/// The list is a plain `VStack` of rows rather than a `List`. Settings sizes
/// its window to the height of the selected pane by measuring the pane's
/// scroll view (see `SettingsWindowController.fitWindowToPaneIfNeeded`), and a
/// `List` brings a second scroll view of its own with an intrinsic height that
/// wants to fill whatever it is given — the two size against each other. A
/// handful of rows doesn't need scrolling anyway; what it needs is to be
/// exactly as tall as it is.
struct ProfilesPane: View {
    @ObservedObject private var store = ProfileStore.shared
    @ObservedObject private var themes = ThemeStore.shared
    @FocusState.Binding var focus: SettingsField?

    @State private var selection: UUID?
    /// The selected profile's environment, as ordered rows.
    ///
    /// `Profile.environment` is a dictionary, which has no order to edit in
    /// and no identity to bind a text field to — a row being typed into would
    /// jump as soon as its key sorted differently. These rows hold that order
    /// and identity; `commitEnvironment` folds them back into the dictionary.
    @State private var envRows: [EnvRow] = []

    init(focus: FocusState<SettingsField?>.Binding) {
        self._focus = focus
    }

    private var selected: Profile? {
        store.profiles.first { $0.id == selection } ?? store.profiles.first
    }

    var body: some View {
        Form {
            Section("Profiles") {
                VStack(spacing: 0) {
                    ForEach(store.profiles) { profile in
                        row(profile)
                    }
                }
                .padding(.vertical, 2)
                // One stop for the whole list, moving with ↑/↓ once focused —
                // the same shape as the category sidebar next to it.
                .focusableControl(.profileList, focus: $focus) { direction in
                    moveSelection(by: -direction)   // ↑ is +1, and up means earlier
                }
                listButtons
            }

            if let profile = selected {
                editor(profile)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if selection == nil { selection = store.profiles.first?.id }
            loadEnvironment()
        }
        .onChange(of: selection) { _, _ in loadEnvironment() }
    }

    // MARK: list

    private func row(_ profile: Profile) -> some View {
        let isSelected = profile.id == selected?.id
        let isDefault = profile.id == store.defaultProfile.id
        return HStack(spacing: 6) {
            Text(profile.name)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            if isDefault {
                // The default is the one ⌘T opens, which is otherwise
                // invisible: every profile looks alike in a list of names.
                Text("⌘T")
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
            }
            Spacer()
            if !profile.isPlainLoginShell {
                Text(profile.command)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { selection = profile.id }
    }

    private var listButtons: some View {
        HStack(spacing: 8) {
            Button { add() } label: { Image(systemName: "plus") }
                .focusableControl(.profileAdd, focus: $focus, onActivate: { add() })
                .help("Add a profile")
            Button { remove() } label: { Image(systemName: "minus") }
                .disabled(store.profiles.count < 2)
                .focusableControl(.profileRemove, focus: $focus, onActivate: { remove() })
                .help(store.profiles.count < 2
                      ? "The last profile can't be removed — ⌘T needs something to run"
                      : "Remove the selected profile")
            Spacer()
            Button { move(by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(!canMove(by: -1))
                .focusableControl(.profileMoveUp, focus: $focus, onActivate: { move(by: -1) })
                .help("Move up — the order here is the order in the New Tab menu, and which profile ⌘⌥1–9 open")
            Button { move(by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(!canMove(by: 1))
                .focusableControl(.profileMoveDown, focus: $focus, onActivate: { move(by: 1) })
                .help("Move down")
        }
        .buttonStyle(.bordered)
    }

    // MARK: editor

    @ViewBuilder
    private func editor(_ profile: Profile) -> some View {
        Section("Settings for \"\(profile.name)\"") {
            LabeledContent("Name") {
                TextField("Name", text: text(\.name))
                    .labelsHidden()
                    .focused($focus, equals: .profileName)
            }
            LabeledContent("Command") {
                VStack(alignment: .leading, spacing: 2) {
                    TextField("$SHELL -l", text: text(\.command))
                        .labelsHidden()
                        .focused($focus, equals: .profileCommand)
                    Text(profile.isPlainLoginShell
                         ? "Empty runs your login shell, exactly as ⌘T always has."
                         : "Run directly, not through a shell — $HOME and globs are not expanded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Directory") {
                HStack(spacing: 6) {
                    TextField("Home", text: text(\.directory))
                        .labelsHidden()
                        .focused($focus, equals: .profileDirectory)
                    Button("Choose…") { chooseDirectory() }
                        .focusableControl(.profileChooseDirectory, focus: $focus,
                                          onActivate: { chooseDirectory() })
                }
            }
            Picker("Theme", selection: themeBinding) {
                Text("Follow Appearance").tag(ProfilesPane.followAppearance)
                Divider()
                ForEach(themes.allThemes) { Text($0.name).tag($0.id) }
            }
            .focusableControl(.profileTheme, focus: $focus) { direction in
                var current = themeBinding.wrappedValue
                stepSelection(&current,
                              in: [Self.followAppearance] + themes.allThemes.map(\.id),
                              by: direction)
                themeBinding.wrappedValue = current
            }
            Toggle("Open this profile with ⌘T", isOn: defaultBinding)
                .focusableControl(.profileDefault, focus: $focus,
                                  onActivate: { defaultBinding.wrappedValue.toggle() })
        }

        Section("Environment") {
            if envRows.isEmpty {
                Text("No extra variables. The child inherits mTerm's environment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach($envRows) { $row in
                HStack(spacing: 6) {
                    TextField("NAME", text: $row.key)
                        .frame(width: 150)
                        .onChange(of: row.key) { _, _ in commitEnvironment() }
                    Text("=").foregroundStyle(.secondary)
                    TextField("value", text: $row.value)
                        .onChange(of: row.value) { _, _ in commitEnvironment() }
                    Button { removeEnvRow(row.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                Spacer()
                Button("Add Variable") {
                    envRows.append(EnvRow(key: "", value: ""))
                }
                .focusableControl(.profileEnvAdd, focus: $focus,
                                  onActivate: { envRows.append(EnvRow(key: "", value: "")) })
            }
        }

        Section {
            Text("Profiles are files in ~/Library/Application Support/mTerm/profiles/ — "
                 + "one JSON file each, so a profile can be shared or checked into a repo "
                 + "by copying it. Changes here apply to tabs opened afterwards; a running "
                 + "tab keeps the shell it started with.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: bindings

    /// Sentinel for "no override" in the theme picker. A `Picker` can't tag a
    /// row with nil, and no real theme id is empty.
    private static let followAppearance = ""

    /// A binding onto one of the selected profile's string fields, writing
    /// straight through to the store — which persists. That is a file write
    /// per keystroke, matching how `AppSettings` already saves on every
    /// change; the files are a few hundred bytes.
    private func text(_ keyPath: WritableKeyPath<Profile, String>) -> Binding<String> {
        Binding(
            get: { selected?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard var p = selected else { return }
                p[keyPath: keyPath] = newValue
                store.update(p)
                // A rename has to reach the New Tab submenu, which shows these
                // names. Rebuilding it is a few NSMenuItems.
                MainMenu.rebuildProfilesMenu()
            }
        )
    }

    private var themeBinding: Binding<String> {
        Binding(
            get: { selected?.themeId ?? Self.followAppearance },
            set: { newValue in
                guard var p = selected else { return }
                p.themeId = newValue == Self.followAppearance ? nil : newValue
                store.update(p)
            }
        )
    }

    /// Turning the toggle *off* would leave no default at all, so it only ever
    /// turns on — switching the default to this profile. Off is reachable by
    /// making another profile the default, which is the only coherent way to
    /// express it.
    private var defaultBinding: Binding<Bool> {
        Binding(
            get: { selected?.id == store.defaultProfile.id },
            set: { isOn in
                guard isOn, let p = selected else { return }
                store.setDefault(p.id)
                MainMenu.rebuildProfilesMenu()
            }
        )
    }

    // MARK: actions

    private func add() {
        let p = store.add()
        selection = p.id
        MainMenu.rebuildProfilesMenu()
    }

    private func remove() {
        guard let p = selected, store.profiles.count > 1 else { return }
        let index = store.profiles.firstIndex(of: p)
        store.remove(id: p.id)
        // Select whatever took its place, or the new last one.
        if let index {
            selection = store.profiles[min(index, store.profiles.count - 1)].id
        } else {
            selection = store.profiles.first?.id
        }
        MainMenu.rebuildProfilesMenu()
    }

    private func canMove(by delta: Int) -> Bool {
        guard let p = selected, let i = store.profiles.firstIndex(of: p) else { return false }
        let target = i + delta
        return target >= 0 && target < store.profiles.count
    }

    private func move(by delta: Int) {
        guard canMove(by: delta), let p = selected,
              let i = store.profiles.firstIndex(of: p) else { return }
        // `move(fromOffsets:toOffset:)` takes an insertion point, which is one
        // past the destination index when moving down.
        store.move(fromOffsets: IndexSet(integer: i),
                   toOffset: delta < 0 ? i - 1 : i + 2)
        MainMenu.rebuildProfilesMenu()
    }

    private func moveSelection(by delta: Int) {
        guard let p = selected, let i = store.profiles.firstIndex(of: p) else { return }
        let next = min(max(i + delta, 0), store.profiles.count - 1)
        selection = store.profiles[next].id
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the directory this profile's tabs start in"
        if let current = selected?.directory, !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (current as NSString).expandingTildeInPath)
        }
        guard panel.runModal() == .OK, let url = panel.url, var p = selected else { return }
        // Stored with a leading `~` when it's inside the home directory, so a
        // profile file stays portable between machines and users.
        let home = NSHomeDirectory()
        let path = url.path
        p.directory = path == home ? "~"
            : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count)
            : path
        store.update(p)
    }

    // MARK: environment

    private func loadEnvironment() {
        let env = selected?.environment ?? [:]
        envRows = env.keys.sorted().map { EnvRow(key: $0, value: env[$0]!) }
    }

    private func removeEnvRow(_ id: UUID) {
        envRows.removeAll { $0.id == id }
        commitEnvironment()
    }

    /// Folds the rows back into the profile. A row with an empty name is kept
    /// on screen but left out of the profile — that's a row being typed, not
    /// a variable named "".
    private func commitEnvironment() {
        guard var p = selected else { return }
        var env: [String: String] = [:]
        for row in envRows {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            env[key] = row.value
        }
        guard env != p.environment else { return }
        p.environment = env
        store.update(p)
    }
}

/// One editable environment variable. Identity is the row's, not the key's, so
/// renaming a variable doesn't destroy the field being typed into.
private struct EnvRow: Identifiable, Equatable {
    let id = UUID()
    var key: String
    var value: String
}
