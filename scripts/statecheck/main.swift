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

section("device control strings")
do {
    // ESC P used to fall through as a plain ESC dispatch, so the payload
    // printed as text: `tmux -CC` put a literal "1000p" on the screen.
    let (state, feed) = buffer(cols: 20, rows: 3)
    feed("\u{1b}P1000p%begin 1 2 3\r\n\u{1b}\\after")
    check("a DCS payload is not printed as text",
          row(state.snapshot(), 0) == "after",
          "row 0 is \"\(row(state.snapshot(), 0))\"")

    final class Recorder: ParserSink {
        var text = ""
        var starts: [(params: [Int], final: UInt8)] = []
        var payload: [UInt8] = []
        var ends = 0
        func parserPrint(_ scalar: Unicode.Scalar) { text.unicodeScalars.append(scalar) }
        func parserExecute(_ control: UInt8) {}
        func parserCSI(_ p: [Int], marker: UInt8?, intermediates: [UInt8], final: UInt8) {}
        func parserOSC(_ data: [UInt8], terminator: UInt8) {}
        func parserESC(_ final: UInt8, intermediates: [UInt8]) {}
        func parserDCSStart(_ params: [Int], intermediates: [UInt8], final: UInt8) {
            starts.append((params, final))
        }
        func parserDCSPut(_ bytes: ArraySlice<UInt8>) { payload.append(contentsOf: bytes) }
        func parserDCSEnd() { ends += 1 }
    }

    let recorder = Recorder()
    let parser = Parser()
    parser.sink = recorder
    func send(_ s: String) {
        Array(s.utf8).withUnsafeBufferPointer { parser.feed(bytes: $0) }
    }
    send("\u{1b}P1000p")
    check("the introducer reports its parameter and final byte",
          recorder.starts.first?.params == [1000]
          && recorder.starts.first?.final == UInt8(ascii: "p"))
    send("hello")
    check("payload streams before any terminator arrives",
          String(decoding: recorder.payload, as: UTF8.self) == "hello")
    check("and the string is still open", recorder.ends == 0)

    // The ordering that a naive implementation gets wrong: the trailing
    // payload has to be delivered before the end, not after it.
    recorder.payload = []
    send(" world\u{1b}\\")
    check("the last payload arrives before the end is reported",
          String(decoding: recorder.payload, as: UTF8.self) == " world" && recorder.ends == 1)
    send("visible")
    check("text after the terminator prints again", recorder.text == "visible")
}

section("string sequences that are not OSC")
do {
    // Inside tmux, TERM goes screen-like and a shell starts setting the window
    // name with `ESC k <name> ST`. oh-my-zsh sets it to the command it is
    // about to run, so before this was handled, running `cd` printed a stray
    // "cd" and running `claude` printed "claude" — at column 0, on the line
    // after the prompt.
    let (state, feed) = buffer(cols: 30, rows: 3)
    feed("\u{1b}kcd\u{1b}\\ok")
    check("a window name is not printed as text",
          row(state.snapshot(), 0) == "ok",
          "row 0 is \"\(row(state.snapshot(), 0))\"")
    check("and it becomes the title", state.snapshot().title == "cd",
          "title is \"\(state.snapshot().title)\"")

    // The real thing, from a captured session: a truncated path, BEL-free,
    // ST-terminated.
    let (b2, f2) = buffer(cols: 40, rows: 3)
    f2("\u{1b}k..fd/scratchpad\u{1b}\\$ ls")
    check("the captured form leaves only the prompt",
          row(b2.snapshot(), 0) == "$ ls", "row 0 is \"\(row(b2.snapshot(), 0))\"")
    check("with the name as the title", b2.snapshot().title == "..fd/scratchpad")

    // BEL terminates it too, the way it does an OSC.
    let (b3, f3) = buffer(cols: 30, rows: 3)
    f3("\u{1b}kbell\u{0007}after")
    check("BEL ends a window name", row(b3.snapshot(), 0) == "after",
          "row 0 is \"\(row(b3.snapshot(), 0))\"")

    // APC, PM and SOS carry bodies nothing here reads. They must not print.
    for (name, intro) in [("APC", "_"), ("PM", "^"), ("SOS", "X")] {
        let (b, f) = buffer(cols: 30, rows: 3)
        f("\u{1b}\(intro)secret payload\u{1b}\\visible")
        check("\(name) payload is swallowed, not printed",
              row(b.snapshot(), 0) == "visible",
              "row 0 is \"\(row(b.snapshot(), 0))\"")
    }
}

section("tmux control mode")
do {
    var events: [TmuxEvent] = []
    let client = TmuxControlClient()
    client.onEvent = { events.append($0) }
    func send(_ s: String) { client.feed(Array(s.utf8)[...]) }

    // Captured verbatim from `tmux -CC` 3.7c on attach.
    send("%begin 1788417588 280 0\r\n%end 1788417588 280 0\r\n")
    send("%window-add @0\r\n%sessions-changed\r\n%session-changed $0 0\r\n")
    check("an empty reply block is reported with no lines",
          events.first == .reply(id: 280, lines: [], error: false))
    check("window-add is read", events.contains(.windowAdd(window: "@0")))
    check("sessions-changed is read", events.contains(.sessionsChanged))
    check("session-changed carries id and name",
          events.contains(.sessionChanged(session: "$0", name: "0")))

    events = []
    send("%output %0 \\033[1mbold\\033[0m\r\n")
    let expected = Array("\u{1b}[1mbold\u{1b}[0m".utf8)
    check("octal escapes in %output are decoded",
          events == [.output(pane: "%0", bytes: expected)],
          "got \(events)")

    events = []
    send("%output %0 a\\134b\r\n")
    check("an escaped backslash decodes to one backslash",
          events == [.output(pane: "%0", bytes: Array("a\\b".utf8))])

    events = []
    send("%output %0 \\xzz mid\r\n")
    check("a malformed escape loses one character, not the line",
          events == [.output(pane: "%0", bytes: Array("\\xzz mid".utf8))],
          "got \(events)")

    // The transport splits wherever the PTY read landed, so a line arriving in
    // pieces — including across the CRLF — has to survive.
    events = []
    send("%window-ren")
    send("amed @1 my")
    send(" window\r")
    send("\n")
    check("a line split across four chunks is reassembled",
          events == [.windowRenamed(window: "@1", name: "my window")],
          "got \(events)")

    // A reply body may itself begin with '%': list-panes prints pane ids.
    events = []
    send("%begin 1 7 1\r\n%0: [80x24]\r\n%1: [80x24]\r\n%end 1 7 1\r\n")
    check("a '%' line inside a block is payload, not a notification",
          events == [.reply(id: 7, lines: ["%0: [80x24]", "%1: [80x24]"], error: false)],
          "got \(events)")

    events = []
    send("%begin 1 8 1\r\nno such window\r\n%error 1 8 1\r\n")
    check("an error block is flagged",
          events == [.reply(id: 8, lines: ["no such window"], error: true)])

    events = []
    send("%window-pane-changed @1 %3\r\n")
    check("the active pane change is read — it is what moves a tab's contents",
          events == [.windowPaneChanged(window: "@1", pane: "%3")])

    events = []
    send("%unlinked-window-close @1\r\n")
    check("an unlinked close counts as a close",
          events == [.windowClose(window: "@1")])

    events = []
    send("%exit \r\n")
    send("%exit\r\n")
    check("exit is read with or without a reason", events.count == 2)

    events = []
    send("%paste-buffer-changed buffer0\r\n")
    check("an unhandled notification is surfaced rather than dropped",
          events == [.other(name: "paste-buffer-changed", arguments: "buffer0")])

    check("keys are sent as hex, which needs no quoting",
          TmuxControlClient.hexKeys([0x1b, 0x5b, 0x41]) == "1b 5b 41")

    // A block left open when tmux vanishes must not strand its caller.
    events = []
    send("%begin 1 9 1\r\npartial\r\n")
    client.finish()
    check("an unterminated block is closed as an error on teardown",
          events == [.reply(id: 9, lines: ["partial"], error: true)])
}

section("tmux window-to-tab mapping")
do {
    final class Sink: TmuxPaneSink {
        var received: [UInt8] = []
        var closed = false
        func receive(_ bytes: [UInt8]) { received.append(contentsOf: bytes) }
        func transportClosed() { closed = true }
        var text: String { String(decoding: received, as: UTF8.self) }
    }
    final class Host: TmuxControllerHost, TmuxCommandSink {
        var sinks: [String: Sink] = [:]
        var openOrder: [String] = []
        var closed: [String] = []
        var titles: [String: String] = [:]
        var selected: [String] = []
        var ended = false
        var commands: [String] = []
        func tmuxOpenTab(windowID: String, title: String) -> TmuxPaneSink {
            let sink = Sink()
            sinks[windowID] = sink
            openOrder.append(windowID)
            return sink
        }
        func tmuxCloseTab(windowID: String) { closed.append(windowID) }
        func tmuxSetTabTitle(windowID: String, title: String) { titles[windowID] = title }
        func tmuxSelectTab(windowID: String) { selected.append(windowID) }
        func tmuxDidEnd() { ended = true }
        func sendTmuxCommand(_ command: String) { commands.append(command) }
    }

    let host = Host()
    let controller = TmuxController(host: host, commands: host)
    controller.start(cols: 120, rows: 40)
    check("attaching sizes the tmux client to the tab",
          host.commands.contains("refresh-client -C 120x40"))
    check("and asks for the windows that already exist",
          host.commands.contains { $0.hasPrefix("list-windows") },
          "%window-add only covers what changes after attach")

    // Replayed in the order a real 3.7c session sent them.
    controller.handle(.windowAdd(window: "@0"))
    check("a window opens a tab", host.openOrder == ["@0"])
    check("and asks tmux which panes it has",
          host.commands.contains { $0.contains("list-panes -t @0") })

    // Output before we know where the pane lives — this is where a new
    // window's first prompt arrives.
    controller.handle(.output(pane: "%0", bytes: Array("early".utf8)))
    check("output for an unplaced pane is held, not dropped",
          host.sinks["@0"]?.text == "", "nothing should have been delivered yet")

    controller.handle(.reply(id: 3, lines: ["mtermP @0 %0 active"], error: false))
    check("once the pane is placed, the held output is delivered",
          host.sinks["@0"]?.text == "early", "got \"\(host.sinks["@0"]?.text ?? "")\"")

    controller.handle(.output(pane: "%0", bytes: Array(" then".utf8)))
    check("and later output follows it", host.sinks["@0"]?.text == "early then")

    // A second pane in the same window: only the active one is shown.
    controller.handle(.reply(id: 4, lines: ["mtermP @0 %1"], error: false))
    controller.handle(.output(pane: "%1", bytes: Array("hidden".utf8)))
    check("a non-active pane's output does not reach the tab",
          host.sinks["@0"]?.text == "early then",
          "got \"\(host.sinks["@0"]?.text ?? "")\"")

    controller.handle(.windowPaneChanged(window: "@0", pane: "%1"))
    controller.handle(.output(pane: "%1", bytes: Array("now visible".utf8)))
    check("switching the active pane switches what the tab shows",
          host.sinks["@0"]?.text.hasSuffix("now visible") == true,
          "got \"\(host.sinks["@0"]?.text ?? "")\"")

    // Input goes to the pane the tab is showing, as hex.
    host.commands = []
    controller.sendKeys(window: "@0", bytes: [0x6c, 0x73, 0x0d])
    check("keys go to the active pane as hex",
          host.commands == ["send-keys -t %1 -H 6c 73 0d"],
          "got \(host.commands)")

    host.commands = []
    controller.sendKeys(window: "@nope", bytes: [0x61])
    check("keys for an unknown window go nowhere", host.commands.isEmpty)

    // Renames and selection follow tmux.
    controller.handle(.windowRenamed(window: "@0", name: "editor"))
    check("a rename retitles the tab", host.titles["@0"] == "editor")
    controller.handle(.windowAdd(window: "@1"))
    controller.handle(.reply(id: 5, lines: ["mtermP @1 %2 active"], error: false))
    controller.handle(.sessionWindowChanged(session: "$0", window: "@1"))
    check("tmux moving to another window selects that tab",
          host.selected.last == "@1")

    // Resize goes to the client, once per actual change.
    host.commands = []
    controller.setClientSize(cols: 100, rows: 30)
    controller.setClientSize(cols: 100, rows: 30)
    check("a resize is sent once, not per event",
          host.commands == ["refresh-client -C 100x30"], "got \(host.commands)")

    // Why the format strings carry a tag: tmux emits an unsolicited block on
    // attach, so counting replies in order shifts everything by one, and
    // sniffing the shape of the lines lets any '@' line invent a window.
    host.openOrder = []
    controller.handle(.reply(id: 99, lines: ["@7 not-a-window"], error: false))
    check("an untagged reply cannot invent a window", host.openOrder.isEmpty)
    controller.handle(.reply(id: 100, lines: ["0: zsh* (1 panes) [80x24]"], error: false))
    check("nor can tmux's own attach block", host.openOrder.isEmpty)
    // On attach, %window-add arrives before the list-windows reply, so a
    // window is created with its id as a placeholder and named a moment
    // later. Guarding that out left every tab titled "@0".
    controller.handle(.reply(id: 101, lines: ["mtermW @0 named by list"], error: false))
    check("a name from list-windows reaches a tab that already exists",
          host.titles["@0"] == "named by list", "got \(host.titles["@0"] ?? "nil")")
    controller.handle(.reply(id: 102, lines: ["mtermW @0 @0"], error: false))
    check("but the id placeholder cannot overwrite a real name",
          host.titles["@0"] == "named by list", "got \(host.titles["@0"] ?? "nil")")

    // Closing.
    controller.handle(.windowClose(window: "@1"))
    check("closing a window closes its tab", host.closed.contains("@1"))
    check("and the sink is told", host.sinks["@1"]?.closed == true)

    controller.handle(.exit(reason: ""))
    check("exit closes what is left", host.closed.contains("@0"))
    check("and reports the mode is over", host.ended)
    check("the last window's sink is closed too", host.sinks["@0"]?.closed == true)

    // Nothing should be acted on after the end.
    host.openOrder = []
    controller.handle(.windowAdd(window: "@9"))
    check("events after exit are ignored", host.openOrder.isEmpty)
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
