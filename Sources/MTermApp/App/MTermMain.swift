import AppKit

/// Starting mTerm, as one symbol.
///
/// This is deliberately the only `public` thing in the package: an executable
/// built from another package — one that links this app and adds to it — needs
/// exactly this and nothing else. Everything else stays `package`, which is
/// what keeps the parser's hot path out of reach; see `ParserSink`, where
/// widening access cost a third of parse throughput.
public enum MTermMain {
    /// Held for the life of the process. `NSApplication.delegate` is a weak
    /// reference, and unlike the top-level `let` this replaced, a local would
    /// be free to die as soon as it had been assigned.
    private static var delegate: AppDelegate?

    /// Runs the app, or performs a build-time export and exits.
    public static func run(arguments: [String] = CommandLine.arguments) -> Never {
        exportAssetsIfAsked(arguments)

        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        // NSApplication.run() doesn't come back; this only satisfies `Never`.
        exit(0)
    }

    /// Build-time hooks: render programmatic assets to disk and exit, used by
    /// scripts/build-release.sh so the shipped repo doesn't carry image source
    /// files for the icon or the DMG background.
    private static func exportAssetsIfAsked(_ arguments: [String]) {
        guard arguments.count >= 3 else { return }
        switch arguments[1] {
        case "--export-iconset":
            AppIcon.exportIconset(to: arguments[2])
            exit(0)
        case "--export-dmg-background":
            DmgBackground.exportBackgrounds(to: arguments[2])
            exit(0)
        default:
            break
        }
    }
}
