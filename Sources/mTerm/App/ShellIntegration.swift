import Darwin
import Foundation

/// Installs OSC 133 prompt markers into the user's shell so that prompt/command
/// boundaries can be detected by mTerm. Sets env vars in the current process so
/// every PTY child inherits them.
///
/// Only zsh is supported in v0. The mechanism is the ZDOTDIR trick: we write a
/// wrapper `.zshrc` into a temp directory, point ZDOTDIR at it, and stash the
/// user's original ZDOTDIR in MTERM_USER_ZDOTDIR. The wrapper restores the real
/// ZDOTDIR, re-sources the user's `.zshrc`, then layers in the OSC 133 hooks.
enum ShellIntegration {
    static func install() {
        guard let shell = ProcessInfo.processInfo.environment["SHELL"],
              shell.hasSuffix("/zsh") else { return }
        installZsh()
    }

    private static func installZsh() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(
            "mterm-zdotdir-\(getpid())",
            isDirectory: true
        )
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return
        }

        let zshrc = dir.appendingPathComponent(".zshrc")
        let script = #"""
        # mTerm shell integration wrapper.
        # Restore the user's real ZDOTDIR so subshells and prompt expansions
        # behave normally.
        if [[ -n "$MTERM_USER_ZDOTDIR" ]]; then
            export ZDOTDIR="$MTERM_USER_ZDOTDIR"
        else
            unset ZDOTDIR
        fi
        unset MTERM_USER_ZDOTDIR

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

        do {
            try script.write(to: zshrc, atomically: true, encoding: .utf8)
        } catch {
            return
        }

        if let existing = ProcessInfo.processInfo.environment["ZDOTDIR"], !existing.isEmpty {
            setenv("MTERM_USER_ZDOTDIR", existing, 1)
        } else {
            unsetenv("MTERM_USER_ZDOTDIR")
        }
        setenv("ZDOTDIR", dir.path, 1)
    }
}
