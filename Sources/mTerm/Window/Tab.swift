import AppKit
import Foundation

final class Tab {
    let id = UUID()
    let terminalView: TerminalView
    /// Display title for the sidebar — typically the cwd's basename, falls
    /// back to the shell's OSC title or "mTerm".
    var displayTitle: String = "mTerm"
    /// Which profile started this tab, kept so session restore can bring it
    /// back on the same one. nil means the default profile at the time the
    /// tab was made — deliberately not resolved to an id here, so a tab
    /// opened with ⌘T follows the user's later change of default rather than
    /// pinning itself to whatever was default when it opened.
    let profileId: UUID?

    init(initialCwd: String?, profile: Profile? = nil) {
        let v = TerminalView(frame: .zero)
        // Default to the user's home dir when nothing else is provided.
        // Without this, the shell inherits the parent process's CWD —
        // which for an app launched from /Applications is `/`.
        v.initialCwd = initialCwd ?? profile?.startDirectory() ?? NSHomeDirectory()
        v.profile = profile
        self.terminalView = v
        self.profileId = profile?.id
    }
}
