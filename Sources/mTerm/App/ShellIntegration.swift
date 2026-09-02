import Darwin
import Foundation

/// Gives a shell mTerm's prompt hooks — OSC 133 prompt markers, which drive
/// the gutter dots and jump-to-prompt, and OSC 7 for the cwd, which is what
/// lets a relative path in compiler output become a link.
///
/// Nothing is written to the user's own rc files. Each shell has a way to
/// slip a file in front of them:
///
/// - **zsh:** `ZDOTDIR` points at a directory we own whose `.zshrc` restores
///   the real `ZDOTDIR`, sources the user's startup files, then layers the
///   hooks on top.
/// - **bash:** `--rcfile` replaces `~/.bashrc` with our wrapper, which sources
///   the login files (or `~/.bashrc`, for a non-login shell) itself. bash 3.2,
///   the one in /bin, ignores `$ENV` for interactive shells whatever `--posix`
///   says, so the rcfile route is the one that works on every bash a Mac has.
/// - **fish:** a `vendor_conf.d` snippet reached through `XDG_DATA_DIRS`.
///   fish 4 emits both sequences itself, so the snippet steps aside there and
///   only fills in for 3.x.
///
/// Everything here runs on the main thread from `Pty.spawn`, which is what
/// makes the unsynchronised statics safe.
enum ShellIntegration {
    /// argv and environment edits for one spawn.
    struct Injection {
        var argv: [String]
        /// "KEY=VALUE" sets, a bare "KEY" unsets; applied in the child.
        var env: [String] = []
    }

    /// Shells whose wrapper has been rewritten this launch. The support
    /// directory persists across launches, so a wrapper written by an older
    /// build would otherwise outlive the script it was generated from; one
    /// forced rewrite per launch keeps them in step, and later spawns only
    /// stat the file.
    private static var refreshedThisLaunch = Set<String>()

    /// Where the wrappers live. Deliberately *not* $TMPDIR: the app routinely
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

    /// Scratch history files for zsh, one per live tab. Created and torn down
    /// by the wrapper itself — the app never touches them, which keeps the
    /// shell the only writer and avoids racing it on tab close.
    private static var historyDir: URL? {
        supportDir?.appendingPathComponent("history", isDirectory: true)
    }

    /// Works out which shell `path` is and returns the argv and environment
    /// to start it with, or nil to start it untouched — because integration
    /// is off, the program isn't a shell we know, or its arguments already
    /// take charge of its startup files.
    static func injection(path: String, argv: [String]) -> Injection? {
        guard ThemeStore.shared.settings.shellIntegrationEnabled else { return nil }
        var name = (path as NSString).lastPathComponent
        if name.hasPrefix("-") { name.removeFirst() }
        switch name {
        case "zsh":  return zsh(argv: argv)
        case "bash": return bash(argv: argv)
        case "fish": return fish(argv: argv)
        default:     return nil
        }
    }

    // MARK: zsh

    private static func zsh(argv: [String]) -> Injection? {
        guard let dir = supportDir?.appendingPathComponent("zdotdir", isDirectory: true),
              let history = historyDir,
              ensureWritten(dir.appendingPathComponent(".zshrc"),
                            shell: "zsh",
                            contents: { zshScript(historyDir: history.path) })
        else { return nil }
        var env = ["ZDOTDIR=" + dir.path]
        // The user's real ZDOTDIR, for the wrapper to restore. Read from the
        // app's own environment, which is never modified — nil when they
        // don't have one, the common case, and zsh then falls back to $HOME.
        if let user = ProcessInfo.processInfo.environment["ZDOTDIR"], !user.isEmpty {
            env.append("MTERM_USER_ZDOTDIR=" + user)
        } else {
            env.append("MTERM_USER_ZDOTDIR")
        }
        return Injection(argv: argv, env: env)
    }

    // MARK: bash

    private static func bash(argv: [String]) -> Injection? {
        // Arguments that already decide what bash reads at startup are the
        // user's call; adding --rcfile on top would either be ignored or
        // override them.
        let takesCharge: Set<String> = ["--norc", "--rcfile", "--init-file", "--posix",
                                        "--noprofile", "-c", "--restricted", "-r"]
        if argv.dropFirst().contains(where: { takesCharge.contains($0) }) { return nil }
        guard let dir = supportDir?.appendingPathComponent("bash", isDirectory: true) else { return nil }
        let rc = dir.appendingPathComponent("mterm.bash")
        guard ensureWritten(rc, shell: "bash", contents: { bashScript }) else { return nil }

        // bash reads --rcfile only for an interactive *non-login* shell, so
        // a login request — argv[0] "-bash", or -l/--login — is taken off
        // the command line and handed to the wrapper, which sources the login
        // files itself.
        var out = argv
        var login = false
        if let first = out.first, first.hasPrefix("-"), first.count > 1, !first.hasPrefix("--") {
            // "-bash": the login convention, not an option.
            out[0] = String(first.dropFirst())
            login = true
        }
        out = out.enumerated().filter { i, a in
            guard i > 0 else { return true }
            if a == "-l" || a == "--login" { login = true; return false }
            return true
        }.map { $0.element }
        out.insert(contentsOf: ["--rcfile", rc.path], at: 1)
        var env = ["MTERM_BASH_LOGIN=" + (login ? "1" : "0")]
        // Apple's bash 3.2 prints a "default shell is now zsh" notice on
        // every start unless told not to; other terminals' users set this
        // in a profile file that hasn't been read yet when bash prints it.
        if ProcessInfo.processInfo.environment["BASH_SILENCE_DEPRECATION_WARNING"] == nil {
            env.append("BASH_SILENCE_DEPRECATION_WARNING=1")
        }
        return Injection(argv: out, env: env)
    }

    // MARK: fish

    private static func fish(argv: [String]) -> Injection? {
        if argv.dropFirst().contains(where: { $0 == "--no-config" || $0 == "-N" || $0 == "-c" }) {
            return nil
        }
        // XDG_DATA_DIRS entries are base directories; fish looks for
        // <base>/fish/vendor_conf.d/*.fish in each.
        guard let base = supportDir?.appendingPathComponent("fish", isDirectory: true) else { return nil }
        let snippet = base.appendingPathComponent("fish/vendor_conf.d/mterm.fish")
        guard ensureWritten(snippet, shell: "fish", contents: { fishScript }) else { return nil }
        // Prepend rather than replace: when the variable is unset fish falls
        // back to the XDG defaults, and setting it to just our directory
        // would hide those.
        let existing = ProcessInfo.processInfo.environment["XDG_DATA_DIRS"]
        let rest = (existing?.isEmpty == false) ? existing! : "/usr/local/share:/usr/share"
        return Injection(argv: argv, env: ["XDG_DATA_DIRS=" + base.path + ":" + rest])
    }

    // MARK: files

    /// Writes `file` if it's missing, or unconditionally the first time this
    /// launch asks for it. Returns false when it couldn't — the caller then
    /// leaves the shell alone, because losing the hooks is a far smaller
    /// regression than pointing a shell at a wrapper that isn't there.
    private static func ensureWritten(_ file: URL, shell: String,
                                      contents: () -> String) -> Bool {
        let fm = FileManager.default
        let force = !refreshedThisLaunch.contains(shell)
        if !force && fm.fileExists(atPath: file.path) { return true }
        do {
            try fm.createDirectory(at: file.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try contents().write(to: file, atomically: true, encoding: .utf8)
            refreshedThisLaunch.insert(shell)
            return true
        } catch {
            return false
        }
    }

    /// Wraps `path` in single quotes for safe interpolation into a script —
    /// the default location contains a space ("Application Support").
    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: scripts

    private static func zshScript(historyDir: String) -> String {
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

    /// Read by bash in place of ~/.bashrc. Written for bash 3.2, the one in
    /// /bin: no arrays in PROMPT_COMMAND, no `${var,,}`, no associative
    /// arrays.
    private static let bashScript = #"""
    # mTerm shell integration for bash. bash was started with `--rcfile` so
    # this runs instead of ~/.bashrc; the startup files bash would otherwise
    # have read are sourced here, in the order bash uses.
    if [ "$MTERM_BASH_LOGIN" = 1 ]; then
        # A login shell: the system profile, then the first personal one.
        [ -r /etc/profile ] && . /etc/profile
        for __mterm_f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
            if [ -r "$__mterm_f" ]; then
                . "$__mterm_f"
                break
            fi
        done
        unset __mterm_f
        # bash only runs ~/.bash_logout for shells it started as login shells.
        if [ -r "$HOME/.bash_logout" ]; then
            trap '. "$HOME/.bash_logout"' EXIT
        fi
    else
        # An ordinary interactive shell reads ~/.bashrc and nothing else.
        [ -r "$HOME/.bashrc" ] && . "$HOME/.bashrc"
    fi
    unset MTERM_BASH_LOGIN

    # OSC 7 (cwd reporting), percent-encoded byte by byte under LC_CTYPE=C
    # so a path with a space or non-ASCII in it still produces a parseable URL.
    __mterm_osc7() {
        local url_path='' i ch hexch LC_ALL= LANG= LC_CTYPE=C LC_COLLATE=C
        for ((i = 0; i < ${#PWD}; ++i)); do
            ch="${PWD:$i:1}"
            case "$ch" in
                [/._~A-Za-z0-9-]) url_path="$url_path$ch" ;;
                *) printf -v hexch "%02X" "'$ch"; url_path="$url_path%$hexch" ;;
            esac
        done
        printf '\033]7;file://%s%s\007' "$HOSTNAME" "$url_path"
    }

    # OSC 133 (FinalTerm) semantic prompt markers:
    #   before the prompt → D (exit code of the last command) + A
    #   end of PS1        → B
    #   DEBUG trap        → C, once, for the first command after a prompt
    #
    # The DEBUG trap fires before every simple command — including each part
    # of PROMPT_COMMAND — so it only reports while __mterm_at_prompt is set,
    # and that is raised by the *last* thing in PROMPT_COMMAND and lowered by
    # the first command that runs afterwards: the user's.
    __mterm_at_prompt=0
    __mterm_first=1
    __mterm_precmd() {
        local exit=$?
        if [ "$__mterm_first" = 1 ]; then
            __mterm_first=0
        else
            printf '\033]133;D;%d\007' "$exit"
        fi
        printf '\033]133;A\007'
        __mterm_osc7
        # A prompt framework that rebuilds PS1 from PROMPT_COMMAND would
        # drop the end-of-prompt mark, so it's re-attached here each time.
        case "$PS1" in
            *'133;B'*) ;;
            *) PS1="$PS1"'\[\e]133;B\a\]' ;;
        esac
        # Keep the exit status for anything that runs after us in
        # PROMPT_COMMAND and reads $?.
        return $exit
    }
    __mterm_prompt_ready() {
        __mterm_at_prompt=1
    }
    __mterm_preexec() {
        [ "$__mterm_at_prompt" = 1 ] || return 0
        [ -n "$COMP_LINE" ] && return 0            # tab completion, not a command
        __mterm_at_prompt=0
        printf '\033]133;C\007'
    }
    PROMPT_COMMAND="__mterm_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}; __mterm_prompt_ready"
    trap '__mterm_preexec' DEBUG
    """#

    /// Sourced by fish from vendor_conf.d before the user's config.fish.
    private static let fishScript = #"""
    # mTerm shell integration for fish.
    status is-interactive; or exit
    # fish 4 emits OSC 133 prompt markers and OSC 7 itself; only 3.x needs
    # this. MTERM_FISH_FORCE exists so the snippet can be exercised under a
    # newer fish.
    if test (string split . -- $version)[1] -ge 4; and not set -q MTERM_FISH_FORCE
        exit
    end

    function __mterm_osc7 --on-variable PWD
        printf '\e]7;file://%s%s\a' (hostname) (string escape --style=url -- $PWD | string replace -a %2F /)
    end

    function __mterm_mark_prompt --on-event fish_prompt
        printf '\e]133;A\a'
        __mterm_osc7
        # The end-of-prompt mark has to follow the prompt text, and fish has
        # no event for that, so fish_prompt is wrapped the first time it is
        # about to run — and again if something redefines it later.
        functions -q fish_prompt; or function fish_prompt; echo '> '; end
        if not string match -q '*__mterm_user_prompt*' -- (functions fish_prompt | string join ' ')
            functions -c fish_prompt __mterm_user_prompt
            function fish_prompt
                __mterm_user_prompt
                printf '\e]133;B\a'
            end
        end
    end

    function __mterm_mark_output --on-event fish_preexec
        printf '\e]133;C\a'
    end

    function __mterm_mark_done --on-event fish_postexec
        printf '\e]133;D;%d\a' $status
    end
    """#
}
