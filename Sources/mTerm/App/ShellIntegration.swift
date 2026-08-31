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
    private static var supportDir: URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory,
                                       in: .userDomainMask).first else { return nil }
        return appSupport.appendingPathComponent("mTerm", isDirectory: true)
    }

    private static var zdotdir: URL? {
        supportDir?.appendingPathComponent("zdotdir", isDirectory: true)
    }

    /// Scratch history files, one per live tab. Created and torn down by the
    /// wrapper itself — the app never touches them, which keeps the shell the
    /// only writer and avoids racing it on tab close.
    private static var historyDir: URL? {
        supportDir?.appendingPathComponent("history", isDirectory: true)
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
        guard let history = historyDir else { return false }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try script(historyDir: history.path).write(to: zshrc, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Wraps `path` in single quotes for safe interpolation into the script —
    /// the default location contains a space ("Application Support").
    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func script(historyDir: String) -> String {
        let historyDirLiteral = shellQuote(historyDir)
        return #"""
    # mTerm shell integration wrapper.
    # Restore the user's real ZDOTDIR so subshells and prompt expansions
    # behave normally.
    if [[ -n "$MTERM_USER_ZDOTDIR" ]]; then
        export ZDOTDIR="$MTERM_USER_ZDOTDIR"
    else
        unset ZDOTDIR
    fi
    unset MTERM_USER_ZDOTDIR

    # Per-tab history.
    #
    # HISTFILE has to be set here no matter what: /etc/zshrc runs before this
    # file and resolves ${ZDOTDIR:-$HOME} while ZDOTDIR still points at our
    # wrapper directory, so it currently aims somewhere no other terminal looks.
    #
    # Rather than just pointing it back at the real history, give each tab its
    # own scratch file. oh-my-zsh turns on `share_history`, which otherwise
    # imports every tab's commands into every other tab as they're typed. The
    # scratch file starts *empty*, so zsh only ever appends this tab's own
    # commands to it; the real history is layered into memory further down with
    # `fc -R`, which doesn't get written back. On exit the tab's commands are
    # folded into the real history and the scratch file is deleted.
    __mterm_hist_shared="${ZDOTDIR:-$HOME}/.zsh_history"
    __mterm_hist_dir=\#(historyDirLiteral)
    __mterm_hist_file=""
    if mkdir -p "$__mterm_hist_dir" 2>/dev/null; then
        # Fold back anything left by a tab that died without running its exit
        # hook (crash, kill -9). Claim by rename first so two tabs starting at
        # once can't merge the same file twice. Our own $$ is fair game — we
        # haven't created this tab's file yet, so a match is a dead tab whose
        # pid got recycled.
        #
        # In a function purely so `local_options` can scope null_glob: this runs
        # before the user's rc files, when EXTENDED_GLOB is off and an empty
        # directory would otherwise abort the whole wrapper with "no matches
        # found" — taking oh-my-zsh down with it.
        __mterm_hist_sweep() {
            setopt local_options null_glob
            local f pid
            for f in "$__mterm_hist_dir"/*.zsh_history; do
                [[ -f "$f" ]] || continue
                pid=${${f:t}%%.*}
                if [[ "$pid" != "$$" ]] && kill -0 "$pid" 2>/dev/null; then
                    continue
                fi
                if mv "$f" "$f.merging" 2>/dev/null; then
                    cat "$f.merging" >> "$__mterm_hist_shared" 2>/dev/null
                    rm -f "$f.merging"
                fi
            done
        }
        __mterm_hist_sweep
        unset -f __mterm_hist_sweep

        __mterm_hist_file="$__mterm_hist_dir/$$.zsh_history"
        : >| "$__mterm_hist_file" 2>/dev/null || __mterm_hist_file=""
    fi
    if [[ -n "$__mterm_hist_file" ]]; then
        HISTFILE="$__mterm_hist_file"
    else
        HISTFILE="$__mterm_hist_shared"
    fi

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

    # Seed this tab from the real history and arrange to fold its own commands
    # back in on exit. Deliberately after the user's rc files: `fc -R` fills
    # memory up to HISTSIZE, and reading before oh-my-zsh raises it would
    # truncate the seed to zsh's tiny default. Backs off if the user set
    # HISTFILE themselves — their choice wins.
    if [[ -n "$__mterm_hist_file" && "$HISTFILE" == "$__mterm_hist_file" ]]; then
        [[ -r "$__mterm_hist_shared" ]] && fc -R "$__mterm_hist_shared"
        __mterm_hist_flush() {
            [[ -n "$__mterm_hist_file" ]] || return
            [[ -s "$__mterm_hist_file" ]] && cat "$__mterm_hist_file" >> "$__mterm_hist_shared"
            rm -f "$__mterm_hist_file"
        }
        # Fires on `exit` and on the SIGHUP mTerm sends when a tab is closed.
        zshexit_functions+=(__mterm_hist_flush)
    fi

    # OSC 7 (cwd reporting). Nothing else emits it under mTerm —
    # /etc/zshrc_Apple_Terminal is gated on TERM_PROGRAM=Apple_Terminal — and
    # without it the terminal has no anchor for the relative file paths in
    # command output, so a `src/main.swift` in a compiler error can't be
    # resolved and never lights up as a link. Percent-encoding follows
    # Apple's: byte-by-byte under LC_CTYPE=C, so a path with a space or
    # non-ASCII in it still produces a parseable URL.
    __mterm_osc7() {
        local url_path='' i ch hexch
        local LC_CTYPE=C LC_COLLATE=C LC_ALL= LANG=
        for ((i = 1; i <= ${#PWD}; ++i)); do
            ch="$PWD[i]"
            if [[ "$ch" =~ [/._~A-Za-z0-9-] ]]; then
                url_path+="$ch"
            else
                printf -v hexch "%02X" "'$ch"
                url_path+="%$hexch"
            fi
        done
        printf '\033]7;file://%s%s\007' "$HOST" "$url_path"
    }

    # OSC 133 (FinalTerm) semantic prompt markers:
    #   precmd  → D (exit code of last command) + A (new prompt starting)
    #   PROMPT  → ... B (end of prompt, command input starts)
    #   preexec → C (command output starts)
    __mterm_precmd() {
        local exit=$?
        printf '\033]133;D;%d\007\033]133;A\007' $exit
        __mterm_osc7
    }
    __mterm_preexec() {
        printf '\033]133;C\007'
    }
    PROMPT="$PROMPT"$'%{\e]133;B\a%}'
    precmd_functions=(__mterm_precmd ${(@)precmd_functions:#__mterm_precmd})
    preexec_functions=(__mterm_preexec ${(@)preexec_functions:#__mterm_preexec})
    """#
    }
}
