# mTerm — Specification

A native macOS terminal emulator. Opinionated, GPU-accelerated, focused.

## Positioning

mTerm is an alternative to iTerm2 for developers who want:

- A terminal that feels like a real Mac app (not a port).
- GPU-class rendering performance (Ghostty/Alacritty territory).
- A small, sharp feature set instead of a thousand preferences.

mTerm is **not** trying to be Warp. There are no AI features, no command palettes that rethink the shell, no cloud accounts. It is a fast, beautiful, modern terminal.

## Non-goals

- Cross-platform support. macOS only.
- AI / LLM features (explain, suggest, agentic runs). Out of scope.
- Recursive split panes. Use tmux/zellij inside a tab.
- Mac App Store distribution in v1 (sandbox constraints conflict with shell features).
- A plugin/extension system in v1.

## Stack

| Layer | Choice |
|---|---|
| Language | Swift 5.10+ |
| App shell | AppKit (`NSApplication`, `NSWindow`, `NSWindowController`) |
| Settings UI | SwiftUI hosted in an `NSWindow` |
| Terminal view | Custom `NSView` backed by Metal (`CAMetalLayer`) |
| Text rendering | CoreText for shaping → custom Metal glyph atlas for rasterization/draw |
| PTY | `forkpty(3)` + `posix_spawn`, `Dispatch` I/O sources |
| Terminal parser | Custom VT/xterm parser (`Sendable`, zero-alloc hot path) |
| Persistence | `Codable` JSON in `~/Library/Application Support/mTerm/` |
| Min OS | macOS 14 Sonoma |
| License | MIT |
| Distribution | Signed + notarized DMG via GitHub Releases |

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│ AppKit Shell (NSApp, menus, NSWindow, NSSplitViewController)  │
│  ├─ SidebarView (custom list of tabs)                         │
│  └─ SettingsWindowController (SwiftUI)                        │
├──────────────────────────────────────────────────────────────┤
│ MainWindowController                                          │
│  ├─ owns N Tabs (each Tab owns a Session 1:1)                 │
│  └─ hosts the active tab's TerminalView (NSView + CAMetalLayer) │
├──────────────────────────────────────────────────────────────┤
│ Session                                                       │
│  ├─ PTY (file descriptors, child pid, env, cwd)               │
│  ├─ VTParser → applies ops to TerminalState                   │
│  ├─ TerminalState (grid, scrollback ring buffer, cursor)      │
│  └─ ShellIntegration (OSC 7/133 handling, prompt markers)     │
├──────────────────────────────────────────────────────────────┤
│ Renderer (Metal)                                              │
│  ├─ GlyphAtlas (subpixel-accurate, LRU per font/size/style)   │
│  ├─ CellGrid pipeline (instanced quads, one draw call/frame)  │
│  └─ CursorOverlay, SelectionOverlay, MarkerOverlay            │
└──────────────────────────────────────────────────────────────┘
```

Key boundaries:
- **PTY I/O is off the main thread.** Reads land in a parser actor, which mutates `TerminalState`. The main thread reads a snapshot for rendering.
- **Rendering is pull-based.** The Metal view runs at the display's refresh rate (`CVDisplayLink`/`CADisplayLink`-equivalent) and reads the latest `TerminalState` snapshot. No "redraw on every byte."
- **Input is push-based.** Key events translate to byte sequences and go straight to the PTY write side.

## Window & Tab Model

- **Tabs only. No splits.** One PTY per tab. For multi-pane workflows, use tmux/zellij.
- **Sidebar tab list, not the system tab bar.** Tabs live in a left-hand sidebar (custom `SidebarView` inside an `NSSplitViewController`), not in macOS's `NSWindowTabbing`. The sidebar is collapsible; tab rows show the current CWD basename / shell title. This trades the "merge windows / move tabs across windows" gestures for a denser, always-visible list that scales past ~10 tabs without overflow.
- New tab inherits the current tab's CWD by default (shell-integration aware; falls back to home).
- ⌘T / ⌘W / ⌘⇧[ / ⌘⇧] for tab navigation. ⌘1–⌘9 to jump to tab N.
- Tabs persist across launches if "Restore session" is enabled.

## Terminal Emulation

- **Compatibility target:** xterm-256color, with the subset of escape sequences modern shells/TUIs actually use (vim, neovim, htop, tmux, fzf, less, git pager).
- **True color:** 24-bit RGB sequences fully supported.
- **Unicode:** UAX #11 wide-char widths, UAX #14 line breaking for double-width handling, full grapheme cluster support.
- **Scrollback:** Configurable ring buffer (default 10,000 lines). Stored in memory; no on-disk paging in v1.
- **Mouse:** SGR mouse protocol (1006). Click, drag, scroll, hover all forwarded when an app requests them.
- **Bracketed paste, focus events, alt-screen, save/restore cursor, etc.** — all supported.

## Shell Integration

Classic terminal *look* (a stream of text), but with prompt awareness underneath.

- **Protocol:** Standard OSC 7 (CWD) and OSC 133 (prompt/command/output) sequences.
- **Auto-injection:** On launch, mTerm injects a small integration snippet via `$PROMPT_COMMAND` / `precmd` / fish event for bash/zsh/fish. User can disable in prefs.
- **UI surfaces enabled by integration:**
  - **Prompt markers:** Small gutter dot next to each prompt line. Color reflects the previous command's exit status (green/red/grey for unknown).
  - **Jump-to-prompt:** ⌘↑ / ⌘↓ move the viewport to the previous/next prompt.
  - **Select command:** Triple-click selects a whole command + its output.
  - **CWD tracking:** New tabs inherit the active tab's CWD; window/tab title reflects CWD.

No collapsible "blocks." No reformatting of output. The terminal still looks like a terminal.

## Triggers / Smart Selection

(Kept from iTerm — one of its most loved features.)

- User defines **triggers**: a regex + an action.
- Actions in v1:
  - **Highlight** matched text with a configurable color.
  - **Make clickable**: ⌘-click opens the match (URL → browser; file path → `$EDITOR` or Finder reveal; custom URL scheme).
  - **Run a shell command** with the match as `$1`.
- Triggers run on output as it arrives (post-parse, pre-render). Performance budget: ≤ 1ms per 1KB of output across all triggers.
- Ships with sensible defaults: URLs, absolute/relative file paths, `file:line:col`, git SHAs, IP addresses.

## tmux Integration Mode

(Kept from iTerm — `-CC` mode.)

- When the user runs `tmux -CC` (or `tmux -CC attach`), mTerm detects the control protocol on stdout and switches the tab into **tmux control mode**.
- Each tmux window becomes a native mTerm tab. tmux panes within a window are still rendered by tmux (no native split UI), but the user can move between them with tmux's own keys.
- New native tabs created in this mode forward to `new-window` in tmux.
- Disconnect cleanly when tmux exits.

## Profiles (Simplified)

iTerm's profile model is the canonical example of too much. mTerm's model:

- A profile is just: **name**, **shell command** (defaults to `$SHELL -l`), **startup CWD**, **env vars**, **theme override** (optional).
- That's it. No per-profile keybindings, no per-profile window sizes, no inheritance hierarchy.
- Profiles are launched from the **New Tab** menu (`File > New Tab > <profile>`) or `⌘⌥1–9`.
- A "Default" profile always exists and is used for `⌘T`.
- Profiles are stored as individual JSON files in `~/Library/Application Support/mTerm/profiles/` (easy to share/version).

## Themes

- Theme = ANSI 16 colors + background + foreground + cursor + selection + 4 UI accents.
- Stored as TOML files in `~/Library/Application Support/mTerm/themes/`.
- Ships with a curated set (≤ 10): Tomorrow Night, Solarized (light + dark), Gruvbox, Nord, Dracula, GitHub (light + dark), plus mTerm's own light/dark.
- **macOS appearance aware:** users can pin a light theme + a dark theme; mTerm follows the system appearance switch automatically.
- Live preview in settings: changing the theme updates all open tabs immediately.

## Scrollback Search

- ⌘F opens an inline search bar at the top of the tab.
- Plain text by default, ⌥⌘F toggles regex.
- Case-sensitive when the query contains uppercase ("smart case").
- Matches are highlighted in-place; ⌘G / ⇧⌘G move between them.
- Searches the visible region first, then expands through scrollback incrementally so first results show in < 50ms even on a full buffer.

## Typography & Rendering

- **Font:** SF Mono default. User-selectable monospace fonts via the font picker.
- **Ligatures:** On by default (controlled by an OpenType feature flag in prefs). Renders `==`, `=>`, `!=`, `->` etc. via CoreText shaping.
- **Emoji & complex scripts:** CoreText handles shaping for emoji, CJK, combining marks, RTL. The glyph atlas keys on `(font, glyphID, size, subpixel-x-offset, color-or-not)`.
- **Subpixel positioning:** Glyphs cached at 3 subpixel x-offsets for sharper text at non-integer cell origins.
- **Glyph atlas:** Single Metal texture (e.g. 2048×2048), LRU eviction. Color glyphs (emoji) get an RGBA atlas; monochrome glyphs share an R8 atlas tinted at draw time.
- **Performance budget:**
  - Idle: < 0.1% CPU, 0 GPU work between frames.
  - Steady-state typing: < 1ms input → first pixel.
  - `cat`-ing a 100MB log: ≥ 1 GB/s parse+render throughput on M-series, no dropped frames at 120 Hz.

## Settings UI

- Native macOS `Settings…` window (SwiftUI, hosted in `NSWindow`).
- **Searchable** like Xcode/VS Code: a search field at the top filters settings across all panes by label, description, and keywords.
- Panes:
  1. **General** — startup behavior, session restore, default profile.
  2. **Appearance** — theme (light + dark pinning), font, ligatures, cursor style.
  3. **Profiles** — list + editor.
  4. **Triggers** — list + editor (regex tester inline).
  5. **Keybindings** — view, override, conflict detection.
  6. **Shell Integration** — toggle auto-injection per shell, view installed snippets.
  7. **Advanced** — scrollback size, GPU diagnostics, telemetry (off by default).
- No config file in v1. Settings live in `~/Library/Application Support/mTerm/settings.json`, editable for power users but not the primary interface.

## Keybindings

Sensible Mac defaults out of the box. All overridable.

| Action | Binding |
|---|---|
| New tab | ⌘T |
| Close tab | ⌘W |
| Next/prev tab | ⌘⇧] / ⌘⇧[ (also ⌘` / ⌘⇧`) |
| Jump to tab N | ⌘N (1–9) |
| Find in scrollback | ⌘F |
| Find regex | ⌥⌘F |
| Next/prev match | ⌘G / ⇧⌘G |
| Jump prev/next prompt | ⌘↑ / ⌘↓ |
| Clear screen | ⌘K |
| Reset terminal | ⌥⌘R |
| Toggle full screen | ⌃⌘F |
| Open Settings | ⌘, |

## Persistence

- **Session restore:** On quit, mTerm writes window/tab structure, CWDs, and profile assignments. On launch, it reopens that structure with fresh shell processes (no attempt to restore process state — that's tmux's job).
- All app data: `~/Library/Application Support/mTerm/`
  - `settings.json`
  - `profiles/*.json`
  - `themes/*.toml`
  - `triggers.json`
  - `state.json` (last-session structure)
  - `logs/` (opt-in diagnostic logs)

## Security & Sandboxing

- **No sandbox** in v1 (shell features require full FS access, subprocess spawning, env inheritance).
- Hardened Runtime + notarization for Gatekeeper.
- No network access required by the app itself. Update check (if added later) must be explicit and disclosed.
- Shell integration snippets are read-only on disk; mTerm never writes to user shell rc files without prompting.

## Performance Targets

| Metric | Target |
|---|---|
| Cold launch to first prompt | ≤ 300ms |
| Keystroke → glyph on screen | ≤ 1 frame (8.3ms @ 120Hz) |
| `cat large.log` throughput | ≥ 1 GB/s parse+render on M2+ |
| Scrollback memory | ≤ 200MB for 10k-line buffer with 200-col width |
| Idle CPU | < 0.1% with one open tab |

Performance is tracked via a built-in `--bench` mode that runs canonical workloads and emits numbers, plus a CI job that fails on regression.

## v1 Definition of Done ("Daily-driver minimum")

Required to ship 1.0:

- [ ] AppKit shell, macOS-native tabs, full-screen, window restore
- [ ] Metal-rendered terminal view with subpixel glyph atlas
- [ ] xterm-256color compatibility (vim/neovim/htop/tmux/fzf/less/git verified)
- [ ] PTY + child process management
- [ ] Scrollback (configurable size) + search (plain + regex)
- [ ] Shell integration (bash/zsh/fish), prompt markers, jump-to-prompt
- [ ] Triggers (highlight + clickable URLs/paths + custom)
- [ ] tmux `-CC` integration mode
- [ ] Profiles (simplified model)
- [ ] Themes + macOS appearance switching
- [ ] Searchable SwiftUI settings window
- [ ] Session restore
- [ ] Signed + notarized DMG
- [ ] README, screenshots, simple landing page
- [ ] Performance benchmarks documented

## Out of v1 (potential v1.x / v2)

- Quake-style dropdown terminal (system-wide hotkey).
- SSH-aware session manager (saved hosts, jump hosts, port forwarding UI).
- Plugin system / extension API.
- Image protocols (Sixel, Kitty graphics, iTerm inline images).
- Workspace files (saved tab sets per project).
- Telemetry / crash reporting (opt-in).
- Themes from URL / community theme browser.

## Build Plan (rough sequencing)

1. **Skeleton:** AppKit app + empty Metal `NSView` + a hello-world triangle. (1 wk)
2. **Glyph atlas + text rendering:** static glyph atlas, render a fixed grid of cells. (2 wks)
3. **PTY + parser:** fork a shell, parse VT sequences into a `TerminalState`. Render real shell output. (3 wks)
4. **Input + scrollback + selection:** keyboard, mouse, copy/paste, scrollback ring. (2 wks)
5. **Tabs + windows + persistence:** `NSWindowTabbing`, session restore. (1 wk)
6. **Shell integration + prompt markers:** OSC 133, gutter, jump-to-prompt. (1 wk)
7. **Themes + appearance + settings UI:** SwiftUI settings with search, theme files, live preview. (2 wks)
8. **Triggers + smart selection:** regex engine, action types. (1 wk)
9. **tmux -CC mode:** control protocol, tab mapping. (1 wk)
10. **Polish + bench + release:** notarization, README, screenshots, perf CI. (2 wks)

~16 weeks calendar for one developer; faster with help.
