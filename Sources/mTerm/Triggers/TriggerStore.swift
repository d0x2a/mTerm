import Foundation
import SwiftUI
import simd

/// The trigger list: the two shipped rules plus whatever the user has added.
///
/// Only the user's own triggers are written to disk, in
/// `~/Library/Application Support/mTerm/triggers.json`, alongside the ids of
/// any builtins that have been switched off. Builtins themselves stay in code
/// — see `Trigger.isBuiltin` for why — so a release that improves the URL
/// pattern improves it for everyone rather than only for people who have
/// never opened this pane.
///
/// Main-thread only, like the Settings window that edits it. `TerminalView`
/// reads `generation` from its display-link tick to notice edits.
final class TriggerStore: ObservableObject {
    static let shared = TriggerStore()

    /// The user's own triggers, in evaluation order.
    @Published private(set) var userTriggers: [Trigger] = []
    /// Builtins the user has switched off.
    @Published private(set) var disabledBuiltins: Set<UUID> = []

    /// Bumped on every change. `TerminalView` compares it rather than the
    /// list, so noticing an edit costs an integer compare per frame instead of
    /// an array of regexes.
    @Published private(set) var generation: Int = 0

    private init() {
        let loaded = Self.load()
        userTriggers = loaded.triggers
        disabledBuiltins = loaded.disabled
    }

    /// What the evaluator runs, in order.
    ///
    /// The user's rules go first: "the first to claim a span keeps it", so
    /// putting them ahead is what lets a rule for a particular URL shape beat
    /// the general one. Disabled entries are dropped here rather than in the
    /// evaluator so the count below is the count that actually costs anything.
    /// An empty pattern is dropped too. It compiles to a perfectly valid regex
    /// that matches the empty string at every position — the evaluator throws
    /// those away for having no length, but not before running it against
    /// every line on screen. A rule someone is still typing shouldn't cost a
    /// pass per frame.
    var active: [Trigger] {
        userTriggers.filter { $0.enabled && !$0.pattern.isEmpty }
            + Trigger.builtins.filter { !disabledBuiltins.contains($0.id) }
    }

    /// Everything the Settings list shows: user rules first, then builtins,
    /// enabled or not.
    var all: [Trigger] {
        userTriggers + Trigger.builtins
    }

    // MARK: editing

    @discardableResult
    func add() -> Trigger {
        var n = userTriggers.count + 1
        var name = "Trigger \(n)"
        while all.contains(where: { $0.name == name }) {
            n += 1
            name = "Trigger \(n)"
        }
        // A pattern that matches nothing yet, so a half-typed rule can't start
        // banding the screen before it says anything.
        let t = Trigger(name: name, pattern: "",
                        color: SIMD4(1.0, 0.85, 0.30, 0.35),
                        style: .background,
                        clickAction: nil)
        userTriggers.append(t)
        persist()
        return t
    }

    func update(_ trigger: Trigger) {
        // A builtin's *enabled* flag is the only part of it the user owns, and
        // it lives in `disabledBuiltins`, not in the trigger.
        if trigger.isBuiltin {
            setBuiltin(trigger.id, enabled: trigger.enabled)
            return
        }
        guard let i = userTriggers.firstIndex(where: { $0.id == trigger.id }),
              userTriggers[i] != trigger else { return }
        userTriggers[i] = trigger
        persist()
    }

    func remove(id: UUID) {
        guard !Trigger.builtinIDs.contains(id) else { return }
        userTriggers.removeAll { $0.id == id }
        persist()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        userTriggers.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func setBuiltin(_ id: UUID, enabled: Bool) {
        guard Trigger.builtinIDs.contains(id) else { return }
        let changed = enabled ? disabledBuiltins.remove(id) != nil
                              : disabledBuiltins.insert(id).inserted
        guard changed else { return }
        persist()
    }

    func isEnabled(_ trigger: Trigger) -> Bool {
        trigger.isBuiltin ? !disabledBuiltins.contains(trigger.id) : trigger.enabled
    }

    /// Why a pattern won't compile, or nil if it will. The editor shows this
    /// rather than letting a bad pattern be saved and silently skipped.
    static func patternError(_ pattern: String) -> String? {
        if pattern.isEmpty { return nil }
        do {
            _ = try NSRegularExpression(pattern: pattern)
            return nil
        } catch {
            return (error as NSError)
                .userInfo[NSLocalizedDescriptionKey] as? String
                ?? error.localizedDescription
        }
    }

    // MARK: disk

    private struct Stored: Codable {
        var triggers: [Trigger]
        var disabledBuiltins: [String]

        init(triggers: [Trigger], disabledBuiltins: [String]) {
            self.triggers = triggers
            self.disabledBuiltins = disabledBuiltins
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.triggers = try c.decodeIfPresent([Trigger].self, forKey: .triggers) ?? []
            self.disabledBuiltins =
                try c.decodeIfPresent([String].self, forKey: .disabledBuiltins) ?? []
        }
    }

    static var url: URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("mTerm", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("triggers.json")
    }

    private static func load() -> (triggers: [Trigger], disabled: Set<UUID>) {
        guard let url, let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return ([], []) }
        // A builtin id in the triggers array would shadow the real builtin and
        // give the list two rows with one id; drop them rather than trusting a
        // hand-edited file.
        let triggers = stored.triggers.filter { !Trigger.builtinIDs.contains($0.id) }
        let disabled = Set(stored.disabledBuiltins.compactMap(UUID.init(uuidString:))
                            .filter(Trigger.builtinIDs.contains))
        return (triggers, disabled)
    }

    private func persist() {
        generation += 1
        guard let url = Self.url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let stored = Stored(triggers: userTriggers,
                            disabledBuiltins: disabledBuiltins.map(\.uuidString).sorted())
        guard let data = try? encoder.encode(stored) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
