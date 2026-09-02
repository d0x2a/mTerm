import Foundation

/// A named way to start a tab. Deliberately small: what to run, where, with
/// which extra environment, and optionally in which theme. No per-profile
/// keybindings, window sizes or inheritance — see SPEC.md, "Profiles".
struct Profile: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    /// The command line to run, split shell-style (quotes and backslashes
    /// honoured). Empty runs the user's `$SHELL` as a login shell, which is
    /// what a plain ⌘T has always done.
    var command: String
    /// Directory the command starts in. Empty means the home directory;
    /// a leading `~` is expanded.
    var directory: String
    /// Extra environment for the child, on top of what the app inherited.
    var environment: [String: String]
    /// Theme for this profile's tabs, regardless of the light/dark choice in
    /// Appearance. nil follows the app.
    var themeId: String?
    /// Order in the New Tab menu and for ⌘⌥1–9.
    var position: Int

    init(id: UUID = UUID(),
         name: String,
         command: String = "",
         directory: String = "",
         environment: [String: String] = [:],
         themeId: String? = nil,
         position: Int = 0) {
        self.id = id
        self.name = name
        self.command = command
        self.directory = directory
        self.environment = environment
        self.themeId = themeId
        self.position = position
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, command, directory, environment, themeId, position
    }

    /// Every key but the name is optional on disk, so a hand-written file
    /// that only names a profile still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Profile"
        self.command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        self.directory = try c.decodeIfPresent(String.self, forKey: .directory) ?? ""
        self.environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        self.themeId = try c.decodeIfPresent(String.self, forKey: .themeId)
        self.position = try c.decodeIfPresent(Int.self, forKey: .position) ?? 0
    }

    /// True for a profile that behaves exactly like the built-in default:
    /// login shell, home directory, nothing added.
    var isPlainLoginShell: Bool {
        command.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The directory a new tab starts in, resolved. `override` wins — session
    /// restore hands back the tab's last cwd — then the profile's directory,
    /// then home.
    func startDirectory(override: String? = nil) -> String {
        if let override, !override.isEmpty { return override }
        let trimmed = directory.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return NSHomeDirectory() }
        return (trimmed as NSString).expandingTildeInPath
    }

    /// What to exec for this profile.
    func launchSpec(cwd override: String? = nil) -> LaunchSpec {
        let cwd = startDirectory(override: override)
        let env: [String] = environment.keys.sorted().map { "\($0)=\(environment[$0]!)" }
        let words = ShellWords.split(command)
        if words.isEmpty {
            // The login-shell convention: argv[0] is "-zsh", the real path is
            // the one exec'd. Matches login(1), Terminal.app and ssh, and is
            // what makes zsh/bash read their profile files.
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let base = (shell as NSString).lastPathComponent
            return LaunchSpec(path: shell, argv: ["-" + base], cwd: cwd, env: env)
        }
        let path = LaunchSpec.resolveExecutable(words[0])
        return LaunchSpec(path: path, argv: words, cwd: cwd, env: env)
    }
}

/// Exactly what the PTY needs to start a child.
struct LaunchSpec {
    var path: String
    /// argv as the child sees it; argv[0] may be "-zsh" for a login shell.
    var argv: [String]
    var cwd: String?
    /// "KEY=VALUE" sets, a bare "KEY" unsets; applied in the child only.
    var env: [String]

    /// A bare command name looked up on a PATH richer than the one a GUI
    /// app is launched with. launchd hands the app `/usr/bin:/bin:/usr/sbin:
    /// /sbin`, on which neither `fish` nor anything else from Homebrew can
    /// be found, so a profile that just says `fish` would fail to start.
    /// Names with a slash are used as typed.
    static func resolveExecutable(_ name: String) -> String {
        if name.contains("/") { return (name as NSString).expandingTildeInPath }
        let fm = FileManager.default
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let home = NSHomeDirectory()
        for extra in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
                      home + "/.local/bin", home + "/bin"] where !dirs.contains(extra) {
            dirs.append(extra)
        }
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return name
    }
}

/// Splits a command line the way a POSIX shell tokenises it: whitespace
/// separates words, single quotes take everything literally, double quotes
/// and backslashes escape. No expansion — `$HOME` stays `$HOME`, which is
/// the honest reading of a field that is exec'd rather than handed to a
/// shell.
enum ShellWords {
    static func split(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character? = nil
        var escaped = false
        for ch in line {
            if escaped {
                current.append(ch)
                escaped = false
                inWord = true
                continue
            }
            if let q = quote {
                if ch == q {
                    quote = nil
                } else if ch == "\\" && q == "\"" {
                    escaped = true
                } else {
                    current.append(ch)
                }
                continue
            }
            switch ch {
            case "\\":
                escaped = true
                inWord = true
            case "'", "\"":
                quote = ch
                inWord = true
            case " ", "\t", "\n":
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
            default:
                current.append(ch)
                inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }
}

/// The profiles on disk — one JSON file each under
/// `~/Library/Application Support/mTerm/profiles/`, so a profile can be
/// shared or versioned by copying a file. Main-thread only, like the
/// Settings window that edits it.
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    @Published private(set) var profiles: [Profile] = []

    static var directory: URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("mTerm/profiles", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        profiles = Self.load()
        if profiles.isEmpty {
            profiles = [Profile(name: "Default")]
            persist()
        }
    }

    /// The profile ⌘T uses. Whatever Settings picked, or the first one when
    /// that pick no longer exists.
    var defaultProfile: Profile {
        if let id = ThemeStore.shared.settings.defaultProfileId,
           let p = profiles.first(where: { $0.id.uuidString == id }) {
            return p
        }
        return profiles[0]
    }

    func profile(id: UUID) -> Profile? {
        profiles.first { $0.id == id }
    }

    func setDefault(_ id: UUID) {
        ThemeStore.shared.settings.defaultProfileId = id.uuidString
        objectWillChange.send()
    }

    @discardableResult
    func add() -> Profile {
        var n = profiles.count + 1
        var name = "Profile \(n)"
        while profiles.contains(where: { $0.name == name }) {
            n += 1
            name = "Profile \(n)"
        }
        let p = Profile(name: name, position: profiles.count)
        profiles.append(p)
        persist()
        return p
    }

    func update(_ profile: Profile) {
        guard let i = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        guard profiles[i] != profile else { return }
        profiles[i] = profile
        persist()
    }

    /// The last profile can't go: ⌘T has to have something to run.
    func remove(id: UUID) {
        guard profiles.count > 1, let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles.remove(at: i)
        if ThemeStore.shared.settings.defaultProfileId == id.uuidString {
            ThemeStore.shared.settings.defaultProfileId = nil
        }
        persist()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        profiles.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    // MARK: disk

    private static func load() -> [Profile] {
        guard let dir = directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return [] }
        var out: [Profile] = []
        for name in names where name.hasSuffix(".json") {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let p = try? JSONDecoder().decode(Profile.self, from: data)
            else { continue }
            out.append(p)
        }
        return out.sorted { ($0.position, $0.name) < ($1.position, $1.name) }
    }

    /// Rewrites every profile with its current position and removes files
    /// for profiles that no longer exist.
    private func persist() {
        guard let dir = Self.directory else { return }
        let fm = FileManager.default
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var keep = Set<String>()
        for (i, var p) in profiles.enumerated() {
            p.position = i
            profiles[i] = p
            let file = p.id.uuidString + ".json"
            keep.insert(file)
            if let data = try? encoder.encode(p) {
                try? data.write(to: dir.appendingPathComponent(file), options: .atomic)
            }
        }
        if let names = try? fm.contentsOfDirectory(atPath: dir.path) {
            for name in names where name.hasSuffix(".json") && !keep.contains(name) {
                // Only our own uuid-named files; a stray hand-made file is
                // left alone so a typo can't erase someone's work.
                if UUID(uuidString: String(name.dropLast(5))) != nil {
                    try? fm.removeItem(at: dir.appendingPathComponent(name))
                }
            }
        }
    }
}
