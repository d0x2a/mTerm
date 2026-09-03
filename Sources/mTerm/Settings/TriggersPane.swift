import AppKit
import SwiftUI
import simd

/// Triggers: the list on top, an editor for the selected one below.
///
/// Same shape as `ProfilesPane`, and a plain `VStack` rather than a `List` for
/// the same reason — Settings sizes its window to the pane's scroll view.
struct TriggersPane: View {
    @ObservedObject private var store = TriggerStore.shared
    @FocusState.Binding var focus: SettingsField?

    @State private var selection: UUID?
    /// Sample text for the inline tester. Per-pane, not per-trigger: it is a
    /// scratch pad for "does this match what I think it does", not something
    /// worth persisting.
    @State private var sample: String = ""

    init(focus: FocusState<SettingsField?>.Binding) {
        self._focus = focus
    }

    private var selected: Trigger? {
        store.all.first { $0.id == selection } ?? store.all.first
    }

    var body: some View {
        Form {
            Section("Triggers") {
                VStack(spacing: 0) {
                    ForEach(store.all) { row($0) }
                }
                .padding(.vertical, 2)
                .focusableControl(.triggerList, focus: $focus) { direction in
                    moveSelection(by: -direction)
                }
                listButtons
            }

            if let trigger = selected {
                if trigger.isBuiltin {
                    builtinEditor(trigger)
                } else {
                    editor(trigger)
                }
                tester(trigger)
            }

            Section {
                Text("Triggers run over the visible screen every frame, not over "
                     + "output as it scrolls past, so a screen that never changes "
                     + "costs nothing extra — but each enabled pattern is tried "
                     + "against every line on screen. Your own rules are tried "
                     + "before the built-in ones, and the first to claim a span "
                     + "keeps it. Stored in "
                     + "~/Library/Application Support/mTerm/triggers.json.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { if selection == nil { selection = store.all.first?.id } }
    }

    // MARK: list

    private func row(_ trigger: Trigger) -> some View {
        let isSelected = trigger.id == selected?.id
        let on = store.isEnabled(trigger)
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { store.isEnabled(trigger) },
                set: { newValue in
                    var t = trigger
                    t.enabled = newValue
                    store.update(t)
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            swatch(trigger)

            Text(trigger.name)
                .foregroundStyle(isSelected ? Color.white
                                 : on ? Color.primary : Color.secondary)
            if trigger.isBuiltin {
                Text("Built in")
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
            }
            Spacer()
            Text(actionLabel(trigger))
                .font(.caption)
                .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { selection = trigger.id }
    }

    /// A hint of what the rule draws. `.none` styles draw nothing of their own
    /// — they only mark under the pointer — so they get an outline rather than
    /// a fill, which would promise a colour the screen never shows.
    private func swatch(_ trigger: Trigger) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(trigger.style == .none ? Color.clear : color(trigger.color))
            .frame(width: 14, height: 14)
            .overlay(RoundedRectangle(cornerRadius: 3)
                .stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
    }

    private func actionLabel(_ trigger: Trigger) -> String {
        switch trigger.clickAction {
        case .openURL:          return "⌘-click opens"
        case .revealFile:       return "⌘-click reveals"
        case .runCommand:       return "⌘-click runs"
        case nil:               return trigger.style == .none ? "does nothing" : "highlights"
        }
    }

    private var listButtons: some View {
        HStack(spacing: 8) {
            Button { add() } label: { Image(systemName: "plus") }
                .focusableControl(.triggerAdd, focus: $focus, onActivate: { add() })
                .help("Add a trigger")
            Button { remove() } label: { Image(systemName: "minus") }
                .disabled(selected?.isBuiltin ?? true)
                .focusableControl(.triggerRemove, focus: $focus, onActivate: { remove() })
                .help(selected?.isBuiltin ?? true
                      ? "Built-in triggers can be switched off, but not removed"
                      : "Remove the selected trigger")
            Spacer()
            Button { move(by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(!canMove(by: -1))
                .focusableControl(.triggerMoveUp, focus: $focus, onActivate: { move(by: -1) })
                .help("Move up — earlier rules claim a span first")
            Button { move(by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(!canMove(by: 1))
                .focusableControl(.triggerMoveDown, focus: $focus, onActivate: { move(by: 1) })
                .help("Move down")
        }
        .buttonStyle(.bordered)
    }

    // MARK: editors

    @ViewBuilder
    private func builtinEditor(_ trigger: Trigger) -> some View {
        Section("\(trigger.name) (built in)") {
            Toggle("Enabled", isOn: Binding(
                get: { store.isEnabled(trigger) },
                set: { store.setBuiltin(trigger.id, enabled: $0) }
            ))
            .focusableControl(.triggerEnabled, focus: $focus, onActivate: {
                store.setBuiltin(trigger.id, enabled: !store.isEnabled(trigger))
            })
            LabeledContent("Pattern") {
                Text(trigger.pattern)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            Text(trigger.id == Trigger.pathID
                 ? "Deliberately loose — it matches things like \"and/or\" too. What keeps "
                   + "it quiet is that a path is only offered once it is found on disk, so "
                   + "the check lives in the terminal view rather than in this pattern."
                 : "Matches an explicit scheme, a dotted host on a known TLD, or localhost "
                   + "and bare IPv4 when a port or path follows. The TLD list is curated so "
                   + "\"main.py\" and \"mTerm.app\" stay plain text.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Built-in patterns are maintained in mTerm and improve between releases, "
                 + "so they can be switched off but not edited. Add your own rule to "
                 + "override one for a particular shape — your rules are tried first.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func editor(_ trigger: Trigger) -> some View {
        Section("Settings for \"\(trigger.name)\"") {
            Toggle("Enabled", isOn: bool(\.enabled))
                .focusableControl(.triggerEnabled, focus: $focus, onActivate: {
                    bool(\.enabled).wrappedValue.toggle()
                })
            LabeledContent("Name") {
                TextField("Name", text: text(\.name))
                    .labelsHidden()
                    .focused($focus, equals: .triggerName)
            }
            LabeledContent("Pattern") {
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Regular expression", text: text(\.pattern))
                        .font(.system(.body, design: .monospaced))
                        .labelsHidden()
                        .focused($focus, equals: .triggerPattern)
                    if let error = TriggerStore.patternError(trigger.pattern) {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("ICU regular expression. A rule that doesn't compile is skipped.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Picker("Style", selection: styleBinding) {
                ForEach(TriggerStyle.allCases) { Text($0.displayName).tag($0) }
            }
            .focusableControl(.triggerStyle, focus: $focus) { direction in
                var s = styleBinding.wrappedValue
                stepSelection(&s, in: TriggerStyle.allCases, by: direction)
                styleBinding.wrappedValue = s
            }
            if trigger.style != .none {
                ColorPicker("Colour", selection: colorBinding, supportsOpacity: true)
                    .focusableControl(.triggerColor, focus: $focus)
            } else {
                Text("Nothing is drawn until the pointer is on the match with ⌘ held, "
                     + "which is how the built-in links behave.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker("⌘-click", selection: actionBinding) {
                ForEach(ActionKind.allCases) { Text($0.displayName).tag($0) }
            }
            .focusableControl(.triggerAction, focus: $focus) { direction in
                var a = actionBinding.wrappedValue
                stepSelection(&a, in: ActionKind.allCases, by: direction)
                actionBinding.wrappedValue = a
            }
            if case .runCommand = trigger.clickAction {
                LabeledContent("Command") {
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("open -a Preview $1", text: commandBinding)
                            .font(.system(.body, design: .monospaced))
                            .labelsHidden()
                            .focused($focus, equals: .triggerCommand)
                        Text("Typed into the tab's shell and run, with $1 replaced by the "
                             + "matched text. It goes to the shell as if you had typed it, "
                             + "so it runs with everything that shell can do.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// The inline tester SPEC asks for: type a line, see what the rule takes
    /// out of it. Runs the same `NSRegularExpression` the evaluator compiles,
    /// so what it reports is what the screen will do.
    @ViewBuilder
    private func tester(_ trigger: Trigger) -> some View {
        Section("Test") {
            TextField("Paste a line of output to test against", text: $sample)
                .font(.system(.body, design: .monospaced))
                .focused($focus, equals: .triggerSample)
            testResult(trigger)
        }
    }

    @ViewBuilder
    private func testResult(_ trigger: Trigger) -> some View {
        if sample.isEmpty || trigger.pattern.isEmpty {
            Text("No sample yet.").font(.caption).foregroundStyle(.secondary)
        } else if let error = TriggerStore.patternError(trigger.pattern) {
            Text(error).font(.caption).foregroundStyle(.red)
        } else {
            let matches = self.matches(pattern: trigger.pattern, in: sample)
            if matches.isEmpty {
                Text("No match.").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(matches.count) match\(matches.count == 1 ? "" : "es"):")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(matches.enumerated()), id: \.offset) { _, m in
                        Text(m)
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(trigger.style == .none
                                        ? Color.accentColor.opacity(0.25)
                                        : color(trigger.color))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
            }
        }
    }

    private func matches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .filter { $0.range.location != NSNotFound && $0.range.length > 0 }
            .map { ns.substring(with: $0.range) }
    }

    // MARK: bindings

    private func text(_ keyPath: WritableKeyPath<Trigger, String>) -> Binding<String> {
        Binding(
            get: { selected?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard var t = selected, !t.isBuiltin else { return }
                t[keyPath: keyPath] = newValue
                store.update(t)
            }
        )
    }

    private func bool(_ keyPath: WritableKeyPath<Trigger, Bool>) -> Binding<Bool> {
        Binding(
            get: { selected?[keyPath: keyPath] ?? false },
            set: { newValue in
                guard var t = selected else { return }
                t[keyPath: keyPath] = newValue
                store.update(t)
            }
        )
    }

    private var styleBinding: Binding<TriggerStyle> {
        Binding(
            get: { selected?.style ?? .background },
            set: { newValue in
                guard var t = selected, !t.isBuiltin else { return }
                t.style = newValue
                store.update(t)
            }
        )
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { color(selected?.color ?? SIMD4(1, 1, 1, 1)) },
            set: { newValue in
                guard var t = selected, !t.isBuiltin else { return }
                let c = NSColor(newValue).usingColorSpace(.sRGB) ?? .white
                t.colorR = Float(c.redComponent)
                t.colorG = Float(c.greenComponent)
                t.colorB = Float(c.blueComponent)
                t.colorA = Float(c.alphaComponent)
                store.update(t)
            }
        )
    }

    private var actionBinding: Binding<ActionKind> {
        Binding(
            get: { ActionKind(selected?.clickAction) },
            set: { newValue in
                guard var t = selected, !t.isBuiltin else { return }
                // Carry the template across a trip through another action, so
                // flicking the pop-up doesn't silently discard what was typed.
                let existing: String
                if case .runCommand(let c) = t.clickAction { existing = c } else { existing = "" }
                t.clickAction = newValue.action(command: existing)
                store.update(t)
            }
        )
    }

    private var commandBinding: Binding<String> {
        Binding(
            get: {
                if case .runCommand(let c) = selected?.clickAction { return c }
                return ""
            },
            set: { newValue in
                guard var t = selected, !t.isBuiltin else { return }
                t.clickAction = .runCommand(newValue)
                store.update(t)
            }
        )
    }

    private func color(_ c: SIMD4<Float>) -> Color {
        Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z),
              opacity: Double(c.w))
    }

    // MARK: actions

    private func add() {
        let t = store.add()
        selection = t.id
    }

    private func remove() {
        guard let t = selected, !t.isBuiltin else { return }
        let index = store.userTriggers.firstIndex(of: t)
        store.remove(id: t.id)
        if let index, !store.userTriggers.isEmpty {
            selection = store.userTriggers[min(index, store.userTriggers.count - 1)].id
        } else {
            selection = store.all.first?.id
        }
    }

    /// Only the user's own rules reorder; the builtins sit after them in a
    /// fixed order, so moving one would have nothing to mean.
    private func canMove(by delta: Int) -> Bool {
        guard let t = selected, !t.isBuiltin,
              let i = store.userTriggers.firstIndex(of: t) else { return false }
        let target = i + delta
        return target >= 0 && target < store.userTriggers.count
    }

    private func move(by delta: Int) {
        guard canMove(by: delta), let t = selected,
              let i = store.userTriggers.firstIndex(of: t) else { return }
        store.move(fromOffsets: IndexSet(integer: i),
                   toOffset: delta < 0 ? i - 1 : i + 2)
    }

    private func moveSelection(by delta: Int) {
        let list = store.all
        guard let t = selected, let i = list.firstIndex(where: { $0.id == t.id }) else { return }
        selection = list[min(max(i + delta, 0), list.count - 1)].id
    }
}

/// `ClickAction` without its associated value, so a `Picker` has something to
/// bind to. The command template is edited in its own field.
private enum ActionKind: String, CaseIterable, Identifiable {
    case none, openURL, revealFile, runCommand

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:        return "Do nothing"
        case .openURL:     return "Open as a URL"
        case .revealFile:  return "Reveal in Finder"
        case .runCommand:  return "Run a command"
        }
    }

    init(_ action: ClickAction?) {
        switch action {
        case .openURL:      self = .openURL
        case .revealFile:   self = .revealFile
        case .runCommand:   self = .runCommand
        case nil:           self = .none
        }
    }

    func action(command: String) -> ClickAction? {
        switch self {
        case .none:        return nil
        case .openURL:     return .openURL
        case .revealFile:  return .revealFile
        case .runCommand:  return .runCommand(command)
        }
    }
}
