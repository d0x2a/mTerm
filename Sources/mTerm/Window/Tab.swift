import AppKit
import Foundation

final class Tab {
    let id = UUID()
    let terminalView: TerminalView
    /// Display title for the sidebar — typically the cwd's basename, falls
    /// back to the shell's OSC title or "mTerm".
    var displayTitle: String = "mTerm"

    init(initialCwd: String?) {
        let v = TerminalView(frame: .zero)
        // Default to the user's home dir when nothing else is provided.
        // Without this, the shell inherits the parent process's CWD —
        // which for an app launched from /Applications is `/`.
        v.initialCwd = initialCwd ?? NSHomeDirectory()
        self.terminalView = v
    }
}
