import Darwin
import Foundation

/// Installs OSC 133 prompt markers into the user's shell so that prompt/command
/// boundaries can be detected by mTerm. Sets env vars in the current process so
/// every PTY child inherits them.
///
/// Only zsh is supported in v0. The mechanism is the ZDOTDIR trick: we write a
/// wrapper `.zshrc` into a directory we own, point ZDOTDIR at it, and stash the
/// user's original ZDOTDIR in MTERM_USER_ZDOTDIR. The wrapper restores the real
/// ZDOTDIR, re-sources the user's `.zshrc`, then layers in the OSC 133 hooks.
///
/// Everything here runs on the main thread — `install()` at launch, and
/// `ensureInstalled()` from `Pty.spawnShell` when a tab opens. That's what makes
/// the unsynchronised statics and the setenv/unsetenv calls safe.
enum ShellIntegration {
    /// The user's real ZDOTDIR, captured before we overwrite it. nil when they
    /// don't have one (the common case — zsh then falls back to $HOME).
    private static var userZdotdir: String?

    /// True once `install()` has decided the shell is zsh. Cleared by
    /// `disable()` if we ever fail to get a wrapper onto disk.
    private static var isActive = false

    /// Where the wrapper lives. Deliberately *not* $TMPDIR: the app routinely
    /// outlives a temp file by weeks, and macOS is free to reap that file out
    /// from under a running instance. When that happened, ZDOTDIR still pointed
    /// at the (now empty) directory, so every new tab spawned a zsh that found
    /// no `$ZDOTDIR/.zshrc` and therefore sourced *none* of the user's startup
    /// files — no oh-my-zsh, no ~/.zprofile, no PATH.
    private static var zdotdir: URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory,
                                       in: .userDomainMask).first else { return nil }
        return appSupport
            .appendingPathComponent("mTerm", isDirectory: true)
            .appendingPathComponent("zdotdir", isDirectory: true)
    }

    static func install() {
        guard let shell = ProcessInfo.processInfo.environment["SHELL"],
              shell.hasSuffix("/zsh") else { return }
        let existing = ProcessInfo.processInfo.environment["ZDOTDIR"]
        userZdotdir = (existing?.isEmpty == false) ? existing : nil
        isActive = true
        // Force the rewrite: the directory now persists across launches, so a
        // wrapper written by an older build would otherwise outlive the script
        // it was generated from.
        refresh(force: true)
    }

    /// Re-asserts the wrapper immediately before a shell is spawned. One `stat`
    /// per tab is nothing next to a fork+exec, and it means a wrapper that
    /// disappears mid-session costs a single tab's prompt rather than silently
    /// degrading every tab until the app is relaunched.
    static func ensureInstalled() {
        refresh(force: false)
    }

    private static func refresh(force: Bool) {
        guard isActive, let dir = zdotdir else { return }
        let zshrc = dir.appendingPathComponent(".zshrc")
        if force || !FileManager.default.fileExists(atPath: zshrc.path) {
            guard writeWrapper(to: dir, zshrc: zshrc) else {
                disable()
                return
            }
        }
        if let user = userZdotdir {
            setenv("MTERM_USER_ZDOTDIR", user, 1)
        } else {
            unsetenv("MTERM_USER_ZDOTDIR")
        }
        setenv("ZDOTDIR", dir.path, 1)
    }

    /// Hands the shell back to the user's own configuration. Losing OSC 133 is a
    /// far smaller regression than leaving ZDOTDIR aimed at a directory with no
    /// `.zshrc` in it, which drops ~/.zshrc and ~/.zprofile along with
    /// everything they pull in (oh-my-zsh, `brew shellenv`, PATH) — and does it
    /// silently, because a missing $ZDOTDIR/.zshrc is not an error to zsh.
    private static func disable() {
        isActive = false
        if let user = userZdotdir {
            setenv("ZDOTDIR", user, 1)
        } else {
            unsetenv("ZDOTDIR")
        }
        unsetenv("MTERM_USER_ZDOTDIR")
    }

    private static func writeWrapper(to dir: URL, zshrc: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try script.write(to: zshrc, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    private static let script = #"""
    # mTerm shell integration wrapper.
    # Restore the user's real ZDOTDIR so subshells and prompt expansions
    # behave normally.
    if [[ -n "$MTERM_USER_ZDOTDIR" ]]; then
        export ZDOTDIR="$MTERM_USER_ZDOTDIR"
    else
        unset ZDOTDIR
    fi
    unset MTERM_USER_ZDOTDIR

    # /etc/zshrc runs before this file and resolves ${ZDOTDIR:-$HOME} while
    # ZDOTDIR still points at our wrapper directory, so HISTFILE currently aims
    # there — stranding mTerm's history somewhere no other terminal looks. Put
    # it back before the user's own rc files run, so they keep the last word.
    HISTFILE="${ZDOTDIR:-$HOME}/.zsh_history"

    # Re-source the user's startup files that zsh skipped because we
    # hijacked ZDOTDIR. /etc/zshenv and /etc/zprofile already ran
    # (system files aren't affected by ZDOTDIR); only the per-user
    # counterparts were missed. .zprofile is critical on macOS because
    # it's where `brew shellenv` typically lives — without it,
    # /opt/homebrew/bin isn't on PATH for GUI-launched sessions.
    __mterm_dir="${ZDOTDIR:-$HOME}"
    [[ -r "$__mterm_dir/.zshenv"   ]] && source "$__mterm_dir/.zshenv"
    [[ -r "$__mterm_dir/.zprofile" ]] && source "$__mterm_dir/.zprofile"
    [[ -r "$__mterm_dir/.zshrc"    ]] && source "$__mterm_dir/.zshrc"
    unset __mterm_dir

    # OSC 133 (FinalTerm) semantic prompt markers:
    #   precmd  → D (exit code of last command) + A (new prompt starting)
    #   PROMPT  → ... B (end of prompt, command input starts)
    #   preexec → C (command output starts)
    __mterm_precmd() {
        local exit=$?
        printf '\033]133;D;%d\007\033]133;A\007' $exit
    }
    __mterm_preexec() {
        printf '\033]133;C\007'
    }
    PROMPT="$PROMPT"$'%{\e]133;B\a%}'
    precmd_functions=(__mterm_precmd ${(@)precmd_functions:#__mterm_precmd})
    preexec_functions=(__mterm_preexec ${(@)preexec_functions:#__mterm_preexec})
    """#
}
