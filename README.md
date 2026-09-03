# mTerm

A native macOS terminal emulator. Opinionated, GPU-accelerated, focused.

![mTerm running scripts/rendercheck.sh: bold, italic, underlined and inverse text, a truecolor gradient, the 256-colour palette, emoji, and double-width Japanese text](docs/renderer.png)

<sub>`scripts/rendercheck.sh` — bold, italic, underline, faint and inverse, truecolor, the 256-colour palette, emoji, double-width CJK and combining marks, all in one screen.</sub>

![mTerm showing a git log in the repository, with the tab sidebar on the left](docs/session.png)

> **Status:** v1.0.0. Every line of the definition of done in [SPEC.md](SPEC.md) has shipped, including tmux `-CC` control mode, profiles, triggers and settings search. Two of the performance targets have been measured rather than asserted: scrollback memory is met with room to spare, throughput is well short of the figure the spec aspired to. Both numbers, and the harness that produced them, are in [docs/BENCHMARKS.md](docs/BENCHMARKS.md).

## Why

mTerm is an alternative to iTerm2 for developers who want:

- A terminal that feels like a real Mac app, not a port.
- GPU-class rendering (Ghostty/Alacritty territory).
- A small, sharp feature set instead of a thousand preferences.

It is **not** trying to be Warp. No AI features, no command palettes that rethink the shell, no cloud accounts. Just a fast, beautiful, modern terminal.

## Install

### Homebrew (recommended)

```bash
brew install --cask d0x2a/tap/mterm
```

### Signed DMG

Grab the latest `.dmg` from [Releases](https://github.com/d0x2a/mTerm/releases), drag mTerm.app to `/Applications`. The DMG is a universal binary, signed with a Developer ID and notarized by Apple, so Gatekeeper will accept it on first launch.

### Build from source

Requires macOS 14+ and Xcode 15+ (or just the command-line tools with Swift 5.10+).

```bash
git clone https://github.com/d0x2a/mTerm.git
cd mTerm
swift run -c release mTerm
```

## What works today

- AppKit-native window with tabbed sidebar (drag to reorder), full-screen, session restore (tabs, their directories and their profiles). The sidebar and split divider tint to the active theme.
- Metal-rendered terminal view with pixel-snapped glyph atlas — crisp text at all sizes, no GPU filtering blur.
- Bold and italic draw in the font's own faces, not a synthesised slant or smear, and the advance is identical across all four so the columns never drift. Underline, faint and inverse too, including the codes that turn each of them back off.
- Resizing reflows the buffer: wrapped lines rejoin and re-split at the new width rather than being cut off, and the grid size shows in a readout while you drag.
- xterm-256color compatibility for vim/neovim/htop/fzf/less/git pagers. 24-bit true color, alt-screen, scroll regions (DECSTBM), DEC line drawing, and synchronized output (DEC 2026) so multi-line redraws land in one frame.
- Mouse reporting: SGR (1006) and legacy encodings for click, drag, motion, and wheel — hold ⇧ to select instead. Bracketed paste, focus events, and device/cursor-position reports.
- East Asian and fullwidth characters take their proper two columns, and combining marks compose into the glyph they follow, so CJK text stays in step with the shell's own cursor arithmetic.
- Scrollback search: plain text by default, regex via ⌥⌘F, smart-case.
- Shell integration for **zsh, bash and fish** via OSC 133: gutter prompt markers (color-coded by exit status), jump to previous/next prompt with ⌘↑ / ⌘↓. Nothing is written to your own rc files — each shell gets a wrapper slipped in front of them (`ZDOTDIR` for zsh, `--rcfile` for bash, a `vendor_conf.d` snippet for fish), and it sources your real startup files before layering the hooks on top.
- Themes: Tomorrow Night, Solarized (light + dark), Nord, Dracula, Gruvbox Dark, plus mTerm's own light + dark. Import any iTerm2 `.itermcolors` file. Auto light/dark switching follows the system appearance.
- macOS notifications for terminal attention events (bell, OSC 9 / OSC 777) — configurable in Settings.
- ⌘-click opens links: URLs (with or without a scheme — `code.d0x2a.com` and `localhost:3000/health` both count) go to the browser, file paths are revealed in Finder. Links aren't drawn differently from the text around them until you point at one: with ⌘ held, the link under the pointer takes the theme's accent colour with an underline to match, and the cursor becomes a hand, one link at a time rather than the whole screen at once. Only paths that exist on disk are offered, so `and/or` stays inert, a `file.swift:42` from compiler output links whole, and a URL that wraps across rows is treated as one address rather than two fragments.
- tmux control mode: run `tmux -CC` and each tmux window becomes a real mTerm tab — ⌘T makes a tmux window, ⌘W closes one, renames and window switches follow tmux both ways. A tab shows its window's **active pane** and follows tmux when you move between panes; mTerm has no splits, and in control mode tmux sends each pane separately rather than a composited screen. One session at a time, and detaching ends the tabs rather than reattaching.
- Close-confirmation when a foreground process is running (`vim`, `ssh`, etc.) — togglable in Settings.
- Font family, size, stroke weight, and line spacing (1.0×–2.0×, default 1.15×) are all adjustable live in Settings.
- Triggers: a regex plus what to do with what it matches — highlight it, recolour it, underline it, or make ⌘-click open it as a URL, reveal it in Finder, or run a command with `$1` as the match. Edited in Settings with an inline tester that runs the real regex, and stored in `triggers.json`. Your rules are tried before the two built-in ones (URLs and file paths), which can be switched off but not edited — their patterns are maintained in mTerm and improve between releases.
- Profiles: a named command, starting directory, environment and optional pinned theme, edited in Settings and stored one JSON file each under `profiles/` so a profile can be shared or checked into a repo. Open one from `File > New Tab with Profile` or ⌘⌥1–9; ⌘T uses whichever is marked default. A profile that pins a theme keeps it whatever the system appearance does, so a production-ssh tab can look different from the rest.
- Settings window organized into Appearance / Profiles / Triggers / General / Notifications panes, with a search field over the sidebar that finds a control by what it's called or by what you'd call it — "antialiasing" finds stroke weight, "history" finds the scrollback depth — and takes you to it with the focus ring on it.
- Shell integration can be switched off in Settings, and the scrollback depth picked there too (1k–100k lines; the pane shows what each costs per tab).

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| New tab | ⌘T |
| New tab with profile N | ⌘⌥1 – ⌘⌥9 |
| Close tab | ⌘W |
| Next / previous tab | ⌘⇧] / ⌘⇧[  (also ⌘` / ⌘⇧`) |
| Jump to tab N | ⌘1 – ⌘9 (⌘9 = last) |
| Find in scrollback | ⌘F |
| Find (regex) | ⌥⌘F |
| Next / previous match | ⌘G / ⇧⌘G |
| Jump previous / next prompt | ⌘↑ / ⌘↓ |
| Toggle full screen | ⌃⌘F |
| Open Settings | ⌘, |

## Configuration

mTerm stores everything under `~/Library/Application Support/mTerm/`:

- `settings.json` — appearance mode, themes, font, close-warning preference.
- `state.json` — restored on next launch (tabs, their directories and profiles, window frame, full-screen state).
- `profiles/*.json` — one file per profile (name, command, directory, environment).
- `triggers.json` — your own trigger rules, plus any built-in ones you've switched off.

There's no config file in v1; everything is editable through the Settings window (⌘,).

## Architecture

See [SPEC.md](SPEC.md) for the full design — stack choices, terminal-emulation scope, performance budgets, and what's deliberately out of scope.

```
AppKit shell  →  MainWindowController + SidebarView
                    │
                    └─ N tabs, one Session each
                            │
                            ├─ PTY (forkpty + posix_spawn, off-main I/O)
                            ├─ VT parser  →  TerminalState
                            └─ Metal Renderer (glyph atlas, instanced cells)
```

## License

MIT — see [LICENSE](LICENSE). Copyright © 2026 Dox2A Labs LLC.
