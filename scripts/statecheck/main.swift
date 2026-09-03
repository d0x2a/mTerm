// Terminal-emulation invariants, checked headlessly.
//
// Compiles the real TerminalState, Parser and Profile sources into a plain
// command-line binary and asserts on the grid they produce. There is no CI in
// this repo, so this is what stands between a parser change and finding out by
// eye — run it after touching the parser, the grid, wrapping, scrollback or
// the palette.
//
// Read-only on purpose: it constructs terminal buffers and decodes JSON, and
// touches nothing under ~/Library/Application Support. (Note that $HOME does
// not redirect `FileManager.applicationSupportDirectory` on macOS, so a test
// that wrote through `ProfileStore.shared` would edit the real profiles even
// under a sandboxed HOME. Don't add one.)
//
// Run it with scripts/statecheck.sh.

import AppKit
import Foundation

// ThemeStore reads NSApp.effectiveAppearance on init, and `Cell` falls back to
// ThemeStore.currentTheme — a static mirror hardcoded to dark until `shared`
// is first built. Both must exist before any terminal object does.
_ = NSApplication.shared
_ = ThemeStore.shared

var failures = 0
func check(_ name: String, _ passed: Bool, _ detail: String = "") {
    print("\(passed ? "  ok  " : "  FAIL") \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !passed { failures += 1 }
}

func section(_ title: String) { print("\n\(title)") }

/// A buffer with a parser already wired to it.
func buffer(cols: Int = 20, rows: Int = 4, scrollback: Int = 100,
            theme: Theme = ThemeStore.currentTheme) -> (TerminalState, (String) -> Void) {
    let state = TerminalState(cols: cols, rows: rows, scrollback: scrollback, theme: theme)
    let parser = Parser()
    parser.sink = state
    return (state, { text in
        Array(text.utf8).withUnsafeBufferPointer { parser.feed(bytes: $0) }
    })
}

/// Row `r` of the viewport as a string, trailing blanks trimmed.
func row(_ snapshot: TerminalSnapshot, _ r: Int) -> String {
    var out = ""
    for c in 0..<snapshot.cols {
        let cell = snapshot.cells[((r + snapshot.rowOffset) % snapshot.rows) * snapshot.cols + c]
        if cell.isContinuation { continue }
        out.append(Character(cell.scalar))
    }
    while out.hasSuffix(" ") { out.removeLast() }
    return out
}

section("printing and wrapping")
do {
    let (s, feed) = buffer(cols: 10, rows: 3)
    feed("hello")
    check("text lands on the first row", row(s.snapshot(), 0) == "hello")

    let (w, wfeed) = buffer(cols: 5, rows: 3)
    wfeed("abcdefgh")
    let snap = w.snapshot()
    check("a long line wraps at the edge",
          row(snap, 0) == "abcde" && row(snap, 1) == "fgh")

    let (u, ufeed) = buffer(cols: 10, rows: 3)
    ufeed("日本語")
    check("double-width characters take two columns each",
          u.snapshot().cursorCol == 6, "cursor at \(u.snapshot().cursorCol)")
}

section("scrollback")
do {
    let (s, feed) = buffer(cols: 20, rows: 3, scrollback: 100)
    for i in 1...10 { feed("line \(i)\r\n") }
    check("rows that scroll off are kept", s.snapshot().scrollbackLines == 8,
          "\(s.snapshot().scrollbackLines) lines")

    let (r, rfeed) = buffer(cols: 20, rows: 3, scrollback: 2)
    for i in 1...10 { rfeed("line \(i)\r\n") }
    check("the ring stops at its configured size", r.snapshot().scrollbackLines == 2,
          "\(r.snapshot().scrollbackLines) lines")

    // The alt screen is vim's and htop's; what they scroll is theirs to lose.
    let (a, afeed) = buffer(cols: 20, rows: 3, scrollback: 100)
    afeed("\u{1b}[?1049h")
    for i in 1...10 { afeed("alt \(i)\r\n") }
    check("alt-screen scrolling files nothing", a.snapshot().scrollbackLines == 0,
          "\(a.snapshot().scrollbackLines) lines")
}

section("erase")
do {
    let (s, feed) = buffer()
    feed("hello\u{1b}[2J")
    check("ED 2 clears the screen", row(s.snapshot(), 0).isEmpty)
    check("ED 2 keeps the cleared screen in history", s.snapshot().scrollbackLines == 1,
          "\(s.snapshot().scrollbackLines) lines")

    // BCE: apps paint a band by setting a background and erasing across it.
    let (b, bfeed) = buffer()
    bfeed("\u{1b}[41m\u{1b}[2J")
    check("erase paints the current SGR background",
          b.snapshot().cells[0].bg == PackedColor(ThemeStore.currentTheme.ansi[1]))
}

section("a tab themed differently from the app")
do {
    // The case a profile theme override creates, and the one no code path had
    // before it: the buffer's palette and the app's disagree.
    let app = ThemeStore.currentTheme
    let pinned = app.id == Theme.mTermLight.id ? Theme.mTermDark : Theme.mTermLight
    check("the checks below are not vacuous", app.foreground != pinned.foreground,
          "app=\(app.name) pinned=\(pinned.name)")

    let (s, feed) = buffer(theme: pinned)
    feed("abc")
    check("blanks beyond the text use the tab's background",
          s.snapshot().cells[5].bg == PackedColor(pinned.background))

    let (e, efeed) = buffer(theme: pinned)
    efeed("abc\u{1b}[2J")
    check("erased cells use the tab's default foreground",
          e.snapshot().cells[0].fg == PackedColor(pinned.foreground),
          "got \(e.snapshot().cells[0].fg), the app's is \(PackedColor(app.foreground))")

    // The blank-row template and what `blankCells` writes have to come from
    // the same palette, or nothing compares equal, every row looks like
    // content, and each repaint files a screenful of nothing into history.
    // Asserting on the *first* clear is what gives this teeth: after one pass
    // every cell has been rewritten, so a consistently-wrong pair matches
    // itself and a later clear looks fine.
    let (f, ffeed) = buffer(rows: 4, theme: pinned)
    ffeed("hello\u{1b}[2J")
    check("clearing files the line that was on screen, not the whole grid",
          f.snapshot().scrollbackLines == 1,
          "filed \(f.snapshot().scrollbackLines) of 4 rows")

    let (t, tfeed) = buffer(theme: pinned)
    tfeed("hi")
    t.applyThemeChange(from: pinned, to: app)
    check("a theme change remaps the cells already printed",
          t.snapshot().cells[0].fg == PackedColor(app.foreground))
    check("and moves the palette the buffer paints in", t.theme.id == app.id)
    tfeed("\u{1b}[2J")
    check("so blanks after it use the new background",
          t.snapshot().cells[0].bg == PackedColor(app.background))
}

section("reflow on resize")
do {
    let (s, feed) = buffer(cols: 8, rows: 4)
    feed("hello world and more")
    s.resize(cols: 20, rows: 4)
    check("a wrapped line rejoins at the wider size",
          row(s.snapshot(), 0) == "hello world and more",
          "got \"\(row(s.snapshot(), 0))\"")
    s.resize(cols: 8, rows: 4)
    check("and re-splits on the way back", row(s.snapshot(), 0) == "hello wo",
          "got \"\(row(s.snapshot(), 0))\"")
}

section("triggers")
do {
    // The store is not touched: it writes to the real triggers.json. What is
    // worth pinning is the evaluator's contract, and that takes a list.
    check("built-in ids are fixed, so \"switched off\" survives a relaunch",
          Trigger.builtins.map(\.id) == [Trigger.urlID, Trigger.pathID])
    check("and the builtins know themselves as built in",
          Trigger.builtins.allSatisfy(\.isBuiltin))
    check("a user trigger does not", !Trigger(name: "x", pattern: "x",
                                              color: SIMD4(1, 1, 1, 1)).isBuiltin)

    check("a broken pattern is reported, not swallowed",
          TriggerStore.patternError("[unclosed") != nil)
    check("a good one isn't", TriggerStore.patternError(#"\berror\b"# ) == nil)
    check("and an empty one is not an error — it is a rule being typed",
          TriggerStore.patternError("") == nil)

    // `runCommand` carries a template, so it has to survive the round trip to
    // disk that the other two cases don't exercise.
    let t = Trigger(name: "Open in Preview", pattern: #"\S+\.png"#,
                    color: SIMD4(1, 0.5, 0, 0.4), style: .background,
                    clickAction: .runCommand("open -a Preview $1"))
    let back = try! JSONDecoder().decode(Trigger.self, from: JSONEncoder().encode(t))
    check("a trigger round-trips through JSON", back == t)
    if case .runCommand(let cmd) = back.clickAction {
        check("including its command template", cmd == "open -a Preview $1")
    } else {
        check("including its command template", false, "action decoded as \(String(describing: back.clickAction))")
    }

    let (state, feed) = buffer(cols: 40, rows: 3)
    feed("see https://example.com/x for details")
    let snap = state.snapshot()

    let builtinsOnly = TriggerEvaluator(triggers: Trigger.builtins)
    let urlMatch = builtinsOnly.evaluate(snapshot: snap).first { $0.trigger.id == Trigger.urlID }
    check("the URL rule finds a URL", urlMatch?.text == "https://example.com/x",
          "got \(urlMatch?.text ?? "nothing")")

    // Ordering is the whole contract for user rules: TriggerStore.active puts
    // them first precisely so a narrower rule can take a span off a builtin.
    let mine = Trigger(name: "Example host", pattern: #"https://example\.com/\S*"#,
                       color: SIMD4(1, 0, 0, 1), style: .background)
    let userFirst = TriggerEvaluator(triggers: [mine] + Trigger.builtins)
    let claimed = userFirst.evaluate(snapshot: snap).first { $0.text.contains("example.com") }
    check("a user rule listed first claims the span off a builtin",
          claimed?.trigger.id == mine.id,
          "claimed by \(claimed?.trigger.name ?? "nothing")")

    let builtinFirst = TriggerEvaluator(triggers: Trigger.builtins + [mine])
    let claimed2 = builtinFirst.evaluate(snapshot: snap).first { $0.text.contains("example.com") }
    check("and listed last it does not", claimed2?.trigger.id == Trigger.urlID)

    let off = TriggerEvaluator(triggers: [Trigger(name: "Off", pattern: "details",
                                                  color: SIMD4(1, 1, 1, 1),
                                                  style: .background, enabled: false)])
    check("a disabled rule is never compiled", off.evaluate(snapshot: snap).isEmpty)

    let broken = TriggerEvaluator(triggers: [Trigger(name: "Bad", pattern: "[unclosed",
                                                     color: SIMD4(1, 1, 1, 1))]
                                  + Trigger.builtins)
    check("a rule that won't compile is skipped without taking the others down",
          broken.evaluate(snapshot: snap).contains { $0.trigger.id == Trigger.urlID })
}

section("profiles")
do {
    // Decoding only — writing would go to the real profiles directory.
    let minimal = try? JSONDecoder().decode(Profile.self, from: Data(#"{"name":"Minimal"}"#.utf8))
    check("a hand-written profile needs only a name", minimal?.name == "Minimal")
    check("an empty command means a login shell", minimal?.isPlainLoginShell == true)
    check("and no directory means home", minimal?.startDirectory() == NSHomeDirectory())

    let p = Profile(name: "Build", command: "/bin/bash -l", directory: "~/src",
                    environment: ["FOO": "bar"])
    let spec = p.launchSpec()
    check("the command splits shell-style", spec.argv == ["/bin/bash", "-l"], "\(spec.argv)")
    check("~ expands in the directory", spec.cwd == NSHomeDirectory() + "/src")
    check("environment is passed as KEY=VALUE", spec.env == ["FOO=bar"])

    check("quotes hold a word together",
          ShellWords.split(#"echo "a b" c"#) == ["echo", "a b", "c"])
    check("$HOME is left alone — this is exec'd, not sourced",
          ShellWords.split("echo $HOME") == ["echo", "$HOME"])

    let login = Profile(name: "Default").launchSpec()
    check("a login shell gets the argv[0] convention", login.argv.first?.hasPrefix("-") == true,
          "\(login.argv)")
}

section("settings search")
do {
    // The index is also the Tab order, so a gap here is a control nobody can
    // reach with the keyboard, not just one search can't find.
    check("every pane has indexed controls",
          SettingsCategory.allCases.allSatisfy { !SettingsIndex.fields(in: $0).isEmpty })
    let fields = SettingsIndex.all.map(\.field)
    check("no control is indexed twice", Set(fields).count == fields.count)
    check("fields(in:) keeps the index's order",
          SettingsIndex.fields(in: .general).first == .warnOnClose)
    check("and covers only its own pane",
          SettingsIndex.fields(in: .notifications).allSatisfy {
              [.notificationsEnabled, .notifyOnBell, .notifyOnlyWhenUnfocused].contains($0)
          })

    check("an empty query matches nothing", SettingsIndex.search("").isEmpty)
    check("whitespace is not a query", SettingsIndex.search("   ").isEmpty)
    check("nonsense matches nothing", SettingsIndex.search("zzzzq").isEmpty)

    // Ranking is the point: a label match has to beat a pane-name match, or
    // "font" leads with whatever happens to sit in a matching pane.
    let font = SettingsIndex.search("font")
    check("\"font\" leads with the font controls",
          font.first?.field == .fontFamily && font.dropFirst().first?.field == .fontSize,
          "got \(font.prefix(2).map(\.label))")

    check("search is case-insensitive",
          SettingsIndex.search("FONT").map(\.field) == font.map(\.field))

    // Keyword-only hits: the word someone arrives with is rarely the label.
    check("\"antialiasing\" finds stroke weight",
          SettingsIndex.search("antialiasing").first?.field == .strokeWeight)
    check("\"history\" finds the scrollback depth",
          SettingsIndex.search("history").first?.field == .scrollbackLines)
    check("\"osc\" finds shell integration",
          SettingsIndex.search("osc").first?.field == .shellIntegration)
    check("\"regex\" finds the trigger pattern",
          SettingsIndex.search("regex").contains { $0.field == .triggerPattern })

    // A word inside a long label should rank as well as its first word does.
    check("\"closing\" finds the close warning",
          SettingsIndex.search("closing").first?.field == .warnOnClose)
    check("\"bell\" finds the bell toggle",
          SettingsIndex.search("bell").first?.field == .notifyOnBell)

    // The two settings that had no UI at all until now.
    check("the scrollback depth is reachable",
          SettingsIndex.fields(in: .general).contains(.scrollbackLines))
    check("so is shell integration",
          SettingsIndex.fields(in: .general).contains(.shellIntegration))
}

section("saved state")
do {
    let saved = SavedState(tabs: [SavedTab(cwd: "/tmp", profileId: "ABC"), SavedTab(cwd: nil)],
                           isFullScreen: true, windowFrame: nil)
    let back = try! JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(saved))
    check("a tab remembers its profile", back.tabs[0].profileId == "ABC")
    check("a plain ⌘T tab has none", back.tabs[1].profileId == nil)
    check("full-screen survives", back.isFullScreen)

    let legacy = try? JSONDecoder().decode(
        SavedState.self, from: Data(#"{"tabs":[{"cwd":"/tmp"}],"isFullScreen":false}"#.utf8))
    check("a state.json written before profiles still loads", legacy?.tabs.count == 1)
    check("and its tabs take the default profile", legacy?.tabs[0].profileId == nil)
}

print("\n\(failures == 0 ? "all checks passed" : "\(failures) check(s) FAILED")")
exit(failures == 0 ? 0 : 1)
