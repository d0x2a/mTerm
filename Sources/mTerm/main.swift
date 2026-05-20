import AppKit

// Build-time hooks: render programmatic assets to disk and exit, used by
// scripts/build-release.sh so the shipped repo doesn't carry image source
// files for the icon or the DMG background.
if CommandLine.arguments.count >= 3 {
    switch CommandLine.arguments[1] {
    case "--export-iconset":
        AppIcon.exportIconset(to: CommandLine.arguments[2])
        exit(0)
    case "--export-dmg-background":
        DmgBackground.exportBackgrounds(to: CommandLine.arguments[2])
        exit(0)
    default:
        break
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
