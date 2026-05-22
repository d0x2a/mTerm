# mTerm

A native macOS terminal emulator. Opinionated, GPU-accelerated, focused.

> **Status:** v0.2.0 — pre-release. Daily-driveable for most workflows, but a few items from [SPEC.md](SPEC.md) are still in progress. Expect changes before 1.0.

## Why

mTerm is an alternative to iTerm2 for developers who want:

- A terminal that feels like a real Mac app, not a port.
- GPU-class rendering (Ghostty/Alacritty territory).
- A small, sharp feature set instead of a thousand preferences.

It is **not** trying to be Warp. No AI features, no command palettes that rethink the shell, no cloud accounts. Just a fast, beautiful, modern terminal.

## Install

### Signed DMG (recommended)

Grab the latest `.dmg` from [Releases](https://github.com/d0x2a/mTerm/releases), drag mTerm.app to `/Applications`. The DMG is signed with a Developer ID and notarized by Apple, so Gatekeeper will accept it on first launch.

### Build from source

Requires macOS 14+ and Xcode 15+ (or just the command-line tools with Swift 5.10+).

```bash
git clone https://github.com/d0x2a/mTerm.git
cd mTerm
swift run -c release mTerm
```

## What works today

- AppKit-native window with tabbed sidebar, full-screen, session restore (tabs + CWDs).
- Metal-rendered terminal view with pixel-snapped glyph atlas — crisp text at all sizes, no GPU filtering blur.
- xterm-256color compatibility for vim/neovim/htop/fzf/less/git pagers. 24-bit true color. Alt-screen, scrollback, mouse tracking.
- Scrollback search: plain text by default, regex via ⌥⌘F, smart-case.
- Shell integration for **zsh** via OSC 133: gutter prompt markers (color-coded by exit status), jump to previous/next prompt with ⌘↑ / ⌘↓.
- Themes: Tomorrow Night, Solarized (light + dark), Nord, Dracula, Gruvbox Dark, plus mTerm's own light + dark. Auto light/dark switching follows the system appearance.
- Triggers engine with built-in regex rules for URLs (⌘-click to open), file paths (⌘-click to reveal), git SHAs, IPv4 addresses.
- Close-confirmation when a foreground process is running (`vim`, `ssh`, etc.) — togglable in Settings.

## Not yet (tracked for v1)

- bash + fish shell integration (zsh only today).
- tmux `-CC` control mode.
- Profiles (named shell configurations).
- Triggers editor UI + `runCommand` action.
- Multi-pane Settings with search.
- Configurable scrollback size from Settings.

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| New tab | ⌘T |
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
- `state.json` — restored on next launch (tabs + window frame + full-screen state).

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
