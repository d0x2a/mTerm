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

    // An erase ending inside a wide glyph leaves one half behind. It is not
    // half of a pair any more, so writing over it must not blank whatever
    // was just printed beside it. The SGR between the letters is what a
    // coloured prompt puts there, and keeps them apart however text is fed.
    let (t, tfeed) = buffer(cols: 10, rows: 3)
    tfeed("中\r\u{1b}[1Kg\u{1b}[mr")
    check("a stray trailing half doesn't take the glyph before it",
          row(t.snapshot(), 0) == "gr", "row 0 is \"\(row(t.snapshot(), 0))\"")

    let (h, hfeed) = buffer(cols: 10, rows: 3)
    hfeed("中\u{8}\u{1b}[Ka\rx")
    check("a stray leading half doesn't take the glyph after it",
          row(h.snapshot(), 0) == "xa", "row 0 is \"\(row(h.snapshot(), 0))\"")

    let (d, dfeed) = buffer(cols: 10, rows: 3)
    dfeed("\u{1b}(0lqqk\u{1b}(Bok")
    check("DEC line drawing still applies to a run of text",
          row(d.snapshot(), 0) == "┌──┐ok", "row 0 is \"\(row(d.snapshot(), 0))\"")
}

section("printable runs")
do {
    // The parser hands printable ASCII over a run at a time, and TerminalState
    // writes a run a span at a time. That has to land exactly as the same
    // glyphs would one by one, which is what this sink does with them: it
    // takes the protocol's default, and forwards everything else untouched.
    final class GlyphAtATime: ParserSink {
        let state: TerminalState
        init(_ state: TerminalState) { self.state = state }
        func parserPrint(_ scalar: Unicode.Scalar) { state.parserPrint(scalar) }
        func parserExecute(_ control: UInt8) { state.parserExecute(control) }
        func parserCSI(_ p: [Int], marker: UInt8?, intermediates: [UInt8], final: UInt8) {
            state.parserCSI(p, marker: marker, intermediates: intermediates, final: final)
        }
        func parserOSC(_ data: [UInt8], terminator: UInt8) { state.parserOSC(data, terminator: terminator) }
        func parserESC(_ final: UInt8, intermediates: [UInt8]) {
            state.parserESC(final, intermediates: intermediates)
        }
        func parserWindowName(_ name: [UInt8]) { state.parserWindowName(name) }
        func parserDCSStart(_ params: [Int], intermediates: [UInt8], final: UInt8) {
            state.parserDCSStart(params, intermediates: intermediates, final: final)
        }
        func parserDCSPut(_ bytes: ArraySlice<UInt8>) { state.parserDCSPut(bytes) }
        func parserDCSEnd() { state.parserDCSEnd() }
    }

    // Everything that decides where a glyph lands or what it overwrites:
    // wide glyphs and marks, cursor moves, erases, backspace over a wide
    // glyph, DEC line drawing, autowrap on and off, scroll regions, inverse,
    // hyperlinks, and runs long enough to wrap several times.
    var seed: UInt64 = 0x9E3779B97F4A7C15
    func next(_ n: Int) -> Int {
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
        return Int(seed % UInt64(n))
    }
    let esc = "\u{1b}"
    let words = ["the", "grid", "x", "a=b", "~/src", "longerthanthenarrowestgrid"]
    var text = ""
    while text.utf8.count < 60_000 {
        switch next(20) {
        case 0: text += "\(esc)[\(1 + next(8));\(1 + next(90))H"
        case 1: text += ["日本語", "한", "😀", "e\u{0301}", "ｆｕ"][next(5)]
        case 2: text += "\r"
        case 3: text += "\u{8}\u{8}"
        case 4: text += next(2) == 0 ? "\(esc)(0" : "\(esc)(B"
        case 5: text += next(2) == 0 ? "\(esc)[?7l" : "\(esc)[?7h"
        case 6: text += next(2) == 0 ? "\(esc)[7m" : "\(esc)[27m"
        case 7: text += "\(esc)]8;;https://x.test/\(next(9))\u{7}"
        case 8: text += "\(esc)]8;;\u{7}"
        case 9: text += "\r\n"
        case 10: text += "\(esc)[\(1 + next(3));\(4 + next(4))r"
        case 11: text += "\(esc)[r"
        case 12: text += "\t"
        case 13: text += "\(esc)[\(next(3))K"
        // Back onto a wide glyph's head, maybe erase up to it, then print
        // across its tail: the one shape where writing a span and writing a
        // glyph at a time have come apart, so it is not left to chance.
        case 16, 17, 18:
            text += ["日本語", "한", "😀", "ｆｕ"][next(4)] + "\u{8}\u{8}"
            if next(2) == 0 { text += "\(esc)[1K" }
            text += words[next(words.count)]
        default: text += words[next(words.count)] + String(repeating: "q", count: next(40))
        }
    }
    let bytes = Array(text.utf8)

    for cols in [80, 13, 1] {
        let runs = TerminalState(cols: cols, rows: 4, scrollback: 50)
        let glyphs = TerminalState(cols: cols, rows: 4, scrollback: 50)
        let runParser = Parser(), glyphParser = Parser()
        runParser.sink = runs
        glyphParser.sink = GlyphAtATime(glyphs)
        // Ragged chunks, like PTY reads, so runs are cut at every kind of edge.
        bytes.withUnsafeBufferPointer { buf in
            var off = 0
            while off < buf.count {
                let n = min(1 + next(700), buf.count - off)
                let chunk = UnsafeBufferPointer(start: buf.baseAddress! + off, count: n)
                runParser.feed(bytes: chunk)
                glyphParser.feed(bytes: chunk)
                off += n
            }
        }
        // Every page of history as well as the screen.
        var same = runs.snapshot().scrollbackLines == glyphs.snapshot().scrollbackLines
            && runs.snapshot().cursorCol == glyphs.snapshot().cursorCol
            && runs.snapshot().cursorRow == glyphs.snapshot().cursorRow
        var offset = 0
        while same {
            let a = runs.viewportSnapshot(scrollOffset: offset)
            let b = glyphs.viewportSnapshot(scrollOffset: offset)
            same = a.rowOffset == b.rowOffset && a.rowWrapped == b.rowWrapped
                && a.cells.withUnsafeBytes { x in b.cells.withUnsafeBytes { y in x.elementsEqual(y) } }
            if offset >= a.scrollbackLines { break }
            offset = min(offset + a.rows, a.scrollbackLines)
        }
        check("runs land exactly as glyphs one at a time at \(cols) columns", same)
    }
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

section("a pane that repaints itself is not reflowed")
do {
    // tmux resizes the pane, the program repaints, and the repaint arrives a
    // moment later. Re-wrapping our copy in between mangles every frame of a
    // window drag — mid-word, as the recording of 2026-09-03 showed.
    let state = TerminalState(cols: 20, rows: 4, scrollback: 50,
                              reflowsOnResize: false)
    let parser = Parser()
    parser.sink = state
    // 30 characters into a 20-column pane, so it genuinely wraps.
    let text = "hello world and more text here"
    Array(text.utf8).withUnsafeBufferPointer { parser.feed(bytes: $0) }
    check("it wrapped on the way in",
          row(state.snapshot(), 0) == "hello world and more"
          && row(state.snapshot(), 1) == " text here",
          "rows: \(row(state.snapshot(), 0).debugDescription), \(row(state.snapshot(), 1).debugDescription)")

    state.resize(cols: 40, rows: 4)
    check("widening leaves the halves where the program put them",
          row(state.snapshot(), 0) == "hello world and more"
          && row(state.snapshot(), 1) == " text here",
          "rows: \(row(state.snapshot(), 0).debugDescription), \(row(state.snapshot(), 1).debugDescription)")

    // An ordinary buffer must still reflow: that is what a shell wants, and
    // what mTerm has always done.
    let (shell, feed) = buffer(cols: 20, rows: 4)
    feed(text)
    shell.resize(cols: 40, rows: 4)
    check("an ordinary buffer still rejoins them",
          row(shell.snapshot(), 0) == text,
          "row 0 is \(row(shell.snapshot(), 0).debugDescription)")
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
    send("%unlinked-window-add @42\r\n")
    check("but an unlinked add does not count as an add",
          events == [.other(name: "unlinked-window-add", arguments: "@42")],
          "it is another session's window — got \(events)")

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
        var openedSizes: [(Int, Int)] = []
        var selected: [String] = []
        var ended = false
        var commands: [String] = []
        func tmuxOpenTab(windowID: String, title: String,
                         cols: Int, rows: Int) -> TmuxPaneSink {
            openedSizes.append((cols, rows))
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
    check("at the tmux client's size, not a placeholder",
          host.openedSizes.first.map { $0 == (120, 40) } ?? false,
          "opened at \(host.openedSizes)")
    check("and asks tmux which panes it has",
          host.commands.contains { $0.contains("list-panes -t @0") })
    check("pane listing is scoped to this session, not the whole server",
          host.commands.contains { $0.hasPrefix("list-panes -s") }
          && !host.commands.contains { $0.hasPrefix("list-panes -a") },
          "-a lists every session's panes and gives each window a tab")

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

    // A window in another session must not appear here. tmux says so
    // explicitly: %unlinked-window-add is "not linked to the current session".
    host.openOrder = []
    controller.handle(.other(name: "unlinked-window-add", arguments: "@42"))
    check("another session's window gets no tab", host.openOrder.isEmpty)

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

section("key encoding")
do {
    // KeyEncoder is what a keystroke becomes on the wire, on every host. It was
    // lifted out of TerminalView's NSEvent handling, and a remote client has to
    // produce exactly these bytes or the shell behaves differently than it does
    // at the Mac's own keyboard — so every branch is pinned here.
    func wire(_ chord: KeyChord) -> String {
        String(decoding: KeyEncoder.bytes(for: chord), as: UTF8.self)
    }
    func key(_ special: KeyChord.Special, _ mods: KeyModifiers = []) -> String {
        wire(KeyChord(special: special, modifiers: mods))
    }
    func text(_ chars: String?, bare: String? = nil, _ mods: KeyModifiers = []) -> String {
        wire(KeyChord(characters: chars, charactersIgnoringModifiers: bare ?? chars, modifiers: mods))
    }
    let esc = "\u{1B}"

    check("enter is CR", key(.enter) == "\r")
    check("shift-enter is ESC CR, so a TUI can tell newline from submit",
          key(.enter, [.shift]) == esc + "\r")
    check("and so is option-enter", key(.enter, [.option]) == esc + "\r")
    check("backspace is DEL", key(.backspace) == "\u{7F}")
    check("option-backspace deletes a word", key(.backspace, [.option]) == esc + "\u{7F}")
    check("forward delete is CSI 3 ~", key(.forwardDelete) == esc + "[3~")
    check("tab is HT", key(.tab) == "\t")
    check("shift-tab is CSI Z", key(.tab, [.shift]) == esc + "[Z")
    check("escape is ESC", key(.escape) == esc)

    check("arrows are CSI A–D", [key(.up), key(.down), key(.right), key(.left)]
          == [esc + "[A", esc + "[B", esc + "[C", esc + "[D"])
    check("modified arrows carry xterm's 1 + shift + 2·option + 4·control",
          key(.up, [.control]) == esc + "[1;5A" && key(.down, [.shift]) == esc + "[1;2B")
    check("all three at once is 8", key(.up, [.shift, .option, .control]) == esc + "[1;8A")
    check("option-left and option-right move by word instead",
          key(.left, [.option]) == esc + "b" && key(.right, [.option]) == esc + "f")
    check("but option-up is still a modified arrow", key(.up, [.option]) == esc + "[1;3A")
    check("home, end, page up, page down",
          [key(.home), key(.end), key(.pageUp), key(.pageDown)]
          == [esc + "[H", esc + "[F", esc + "[5~", esc + "[6~"])

    check("command-anything is an app shortcut, never input",
          text("c", [.command]).isEmpty && key(.enter, [.command]).isEmpty)

    check("option is meta: ESC before the bare key", text("∫", bare: "b", [.option]) == esc + "b")
    check("meta lowercases unless shift is held",
          text("B", bare: "B", [.option]) == esc + "b"
          && text("B", bare: "B", [.option, .shift]) == esc + "B")
    check("meta with no bare key sends nothing", text("x", bare: "", [.option]).isEmpty)

    check("ordinary text passes through", text("a") == "a")
    check("control letters arrive already as the control byte", text("\u{03}", [.control]) == "\u{03}")
    check("text is UTF-8", KeyEncoder.bytes(for: KeyChord(characters: "é")) == [0xC3, 0xA9])
    check("no characters, no bytes", text(nil).isEmpty)
}

section("command blocks")
do {
    // The shape a markdown-rendering TUI prints: prose, a blank line, a
    // command over several lines, a blank line, another command. Nothing in
    // the bytes says which is which — that is the whole problem — so the
    // detector has only the blank lines and the first line's content to work
    // from.
    let (state, feed) = buffer(cols: 60, rows: 14)
    feed("  Two edits to the live Deployment. Order matters:\r\n")
    feed("\r\n")
    feed("  kubectl -n ahead patch deploy app --type=json -p '[{\r\n")
    feed("    \"path\": \"/spec/template/spec/containers/0/env/0\",\r\n")
    feed("    \"value\": {\"name\": \"REDIS_PASSWORD\"}}]'\r\n")
    feed("\r\n")
    feed("  kubectl -n ahead set env deploy/app \\\r\n")
    feed("    'ConnectionStrings__Redis=cache:6379'\r\n")
    let snap = state.snapshot()
    let installed: (String) -> Bool = { $0 == "kubectl" }
    func blockAt(_ r: Int) -> CommandBlock? {
        CommandBlockDetector.block(containingRow: r, snapshot: snap, isExecutable: installed)
    }

    check("a command block is found from any of its rows",
          blockAt(2)?.firstRow == 2 && blockAt(3)?.firstRow == 2 && blockAt(4)?.firstRow == 2)
    check("and it ends at the blank line", blockAt(3)?.lastRow == 4)
    check("the prose paragraph above is not one", blockAt(0) == nil)
    check("nor is a blank row", blockAt(1) == nil)
    check("the second command is its own block",
          blockAt(6)?.firstRow == 6 && blockAt(6)?.lastRow == 7)

    check("the copied text drops the block's common indent",
          blockAt(3)?.text.hasPrefix("kubectl -n ahead patch") == true,
          blockAt(3).map { String($0.text.prefix(24)) } ?? "nil")
    check("but keeps the indent inside it",
          blockAt(3)?.text.contains("\n  \"path\"") == true)
    check("and trims the row padding",
          blockAt(3)?.text.contains("  \n") == false && blockAt(3)?.text.hasSuffix(" ") == false)
    check("a trailing continuation backslash survives",
          blockAt(6)?.text.contains("deploy/app \\\n") == true)

    // A gutter bullet is the renderer talking, not part of the command.
    let (bulleted, feedBullet) = buffer(cols: 40, rows: 6)
    feedBullet("\u{23FA} kubectl get pods\r\n")
    feedBullet("    --namespace ahead\r\n")
    let bulletBlock = CommandBlockDetector.block(containingRow: 0,
                                                 snapshot: bulleted.snapshot(),
                                                 isExecutable: installed)
    check("the bullet in front of a block is not copied",
          bulletBlock?.text == "kubectl get pods\n  --namespace ahead",
          bulletBlock.map { $0.text.debugDescription } ?? "nil")

    // A command too long for the window is still one command.
    let (narrow, feedNarrow) = buffer(cols: 20, rows: 6)
    feedNarrow("kubectl get pods --all-namespaces\r\n")
    let wrapped = CommandBlockDetector.block(containingRow: 1,
                                             snapshot: narrow.snapshot(),
                                             isExecutable: installed)
    check("a wrapped command is copied without the wrap",
          wrapped?.text == "kubectl get pods --all-namespaces",
          wrapped.map { $0.text.debugDescription } ?? "nil")
    check("and marking covers every row it wrapped onto",
          wrapped?.firstRow == 0 && wrapped?.lastRow == 1)

    // A wall of output is not a command block, whatever its first line says.
    let (wall, feedWall) = buffer(cols: 30, rows: 60, scrollback: 0)
    feedWall("kubectl logs -f pod\r\n")
    for i in 0..<50 { feedWall("line \(i) of output\r\n") }
    check("a wall of unbroken output is left alone",
          CommandBlockDetector.block(containingRow: 3, snapshot: wall.snapshot(),
                                     isExecutable: installed) == nil)

    // The gate itself.
    let none: (String) -> Bool = { _ in false }
    check("an installed tool is a command",
          CommandBlockDetector.looksLikeCommand("npm test", isExecutable: { $0 == "npm" }))
    check("a tool you don't have is still one if it carries a flag",
          CommandBlockDetector.looksLikeCommand("terraform apply -auto-approve", isExecutable: none))
    check("a tool you don't have with no flag is not",
          !CommandBlockDetector.looksLikeCommand("pulumi up", isExecutable: none))
    check("prose is not a command",
          !CommandBlockDetector.looksLikeCommand("Two edits to the live Deployment.", isExecutable: none))
    check("a prompt in front of the command is not the command",
          CommandBlockDetector.looksLikeCommand("$ kubectl get pods", isExecutable: { $0 == "kubectl" }))
    check("nor are the environment assignments before it",
          CommandBlockDetector.looksLikeCommand("LOG=debug RUST_BACKTRACE=1 myapp", isExecutable: { $0 == "myapp" }))
    check("sudo is not the command either",
          CommandBlockDetector.looksLikeCommand("sudo systemctl restart nginx", isExecutable: { $0 == "systemctl" }))
    check("a pipeline counts", CommandBlockDetector.looksLikeCommand("cat x | grep y", isExecutable: none))

    // A transcript is a command followed by what it printed. Copying the
    // output back into a shell is never the ask, and neither is the prompt.
    let (transcript, feedTranscript) = buffer(cols: 70, rows: 6)
    feedTranscript("$ kubectl rollout restart deployment/payments-api -n payments\r\n")
    feedTranscript("deployment.apps/payments-api restarted\r\n")
    let tSnap = transcript.snapshot()
    let cmdOnly = CommandBlockDetector.block(containingRow: 0, snapshot: tSnap, isExecutable: installed)
    check("a prompted command stops before its output", cmdOnly?.lastRow == 0)
    check("and the prompt is not copied with it",
          cmdOnly?.text == "kubectl rollout restart deployment/payments-api -n payments",
          cmdOnly.map { $0.text.debugDescription } ?? "nil")
    check("pointing at the output is not pointing at the command",
          CommandBlockDetector.block(containingRow: 1, snapshot: tSnap, isExecutable: installed) == nil)

    // …but a command that continues onto the next lines is still one command.
    let (cont, feedCont) = buffer(cols: 80, rows: 8)
    feedCont("$ kubectl create secret generic payments-db-credentials \\\r\n")
    feedCont("    --from-literal=DB_USER=payments_svc \\\r\n")
    feedCont("    --dry-run=client -o yaml | kubectl apply -f -\r\n")
    feedCont("secret/payments-db-credentials created\r\n")
    let contBlock = CommandBlockDetector.block(containingRow: 1, snapshot: cont.snapshot(),
                                               isExecutable: installed)
    check("continuation lines stay with the command", contBlock?.lastRow == 2)
    check("the backslashes survive the copy",
          contBlock?.text.hasPrefix("kubectl create secret generic payments-db-credentials \\\n") == true,
          contBlock.map { String($0.text.prefix(60)).debugDescription } ?? "nil")
    check("and the output after it is left out",
          contBlock?.text.contains("created") == false)

    // `#` is a comment far more often than it is a root prompt.
    check("a comment keeps its hash",
          CommandBlockDetector.strippingPrompt("# rotate the credentials") == nil)
    check("a variable is not a prompt", CommandBlockDetector.strippingPrompt("$PATH is set") == nil)
    check("a prompt is a sigil and a space",
          CommandBlockDetector.strippingPrompt("$ npm test") == "npm test")

    // How a TUI actually prints a list of commands: a numbered heading, then
    // the command, no blank line between them. The run holds both, so the
    // heading has to be split off or nothing is a target at all.
    let (list, feedList) = buffer(cols: 80, rows: 12)
    feedList(" 1. Recreate the whole secret with new values (idempotent)\r\n")
    feedList("  kubectl create secret generic moonbase-db-creds \\\r\n")
    feedList("    --from-literal=DB_USER=astro_admin \\\r\n")
    feedList("    --dry-run=client -o yaml | kubectl apply -f -\r\n")
    feedList("\r\n")
    feedList("  7. Restart the pods so they pick up the new values\r\n")
    feedList("  kubectl rollout restart deployment/moonbase-api -n lunar-prod\r\n")
    feedList("  kubectl rollout status deployment/moonbase-api -n lunar-prod\r\n")
    let lSnap = list.snapshot()
    func listBlock(_ r: Int) -> CommandBlock? {
        CommandBlockDetector.block(containingRow: r, snapshot: lSnap, isExecutable: installed)
    }
    check("a command under a heading is still found", listBlock(1)?.firstRow == 1)
    check("and the heading is not part of it", listBlock(1)?.lastRow == 3)
    check("the heading itself is not a target", listBlock(0) == nil)
    check("the copy starts at the command",
          listBlock(2)?.text.hasPrefix("kubectl create secret") == true,
          listBlock(2).map { String($0.text.prefix(30)).debugDescription } ?? "nil")
    check("two commands in a row are one block",
          listBlock(6)?.firstRow == 6 && listBlock(6)?.lastRow == 7)
    check("and both are copied",
          listBlock(7)?.text.contains("rollout restart") == true
            && listBlock(7)?.text.contains("rollout status") == true)

    // Not every command runs on with a backslash. A JSON payload just ends
    // mid-quote, and half of it is worse than none.
    check("an unclosed quote keeps the command going",
          CommandBlockDetector.isIncomplete("kubectl patch -p '[{\"op\":\"add\","))
    check("an unclosed brace does too",
          CommandBlockDetector.isIncomplete("foo --data {\"a\": 1"))
    check("a finished command does not",
          !CommandBlockDetector.isIncomplete("kubectl get pods -n prod"))
    check("an apostrophe inside double quotes is not an open quote",
          !CommandBlockDetector.isIncomplete("echo \"don't\""))
    check("an escaped quote is not an open quote",
          !CommandBlockDetector.isIncomplete("echo \\\"x\\\""))

    // A flag only counts near the front of the line. Prose that mentions one
    // arrives at it late — this is a real line from a Claude Code screen, the
    // echo of a prompt, and it was marked as a command until the lookahead.
    check("a sentence that mentions a flag is not a command",
          !CommandBlockDetector.looksLikeCommand(
            "two spaces indent saying --namespace ahead, then echo done.", isExecutable: none))
    check("but a subcommand before the flag still is",
          CommandBlockDetector.looksLikeCommand(
            "aws ec2 describe-instances --region us-east-1", isExecutable: none))
    check("and a flag right after the command name certainly is",
          CommandBlockDetector.looksLikeCommand("terraform apply -auto-approve", isExecutable: none))

    // A heredoc's body is its argument. Copying the opener alone gives a
    // command that sits waiting on stdin, which is worse than copying nothing.
    check("a quoted heredoc delimiter is read",
          CommandBlockDetector.heredocDelimiter("cat <<'EOF' | kubectl apply -f -") == "EOF")
    check("so is a bare one", CommandBlockDetector.heredocDelimiter("cat <<EOF") == "EOF")
    check("and a dashed, double-quoted one",
          CommandBlockDetector.heredocDelimiter("cat <<-\"END\" > f") == "END")
    check("a command with no heredoc has no delimiter",
          CommandBlockDetector.heredocDelimiter("kubectl get pods -n prod") == nil)

    let (here, feedHere) = buffer(cols: 70, rows: 14)
    feedHere(" 5. Update from a heredoc\r\n")
    feedHere("  cat <<'EOF' | kubectl apply -f -\r\n")
    feedHere("  apiVersion: v1\r\n")
    feedHere("  metadata:\r\n")
    feedHere("    name: stripe-api\r\n")
    feedHere("\r\n")                       // a body may contain blank lines
    feedHere("  type: Opaque\r\n")
    feedHere("  EOF\r\n")
    feedHere("secret/stripe-api configured\r\n")
    let hSnap = here.snapshot()
    func hereBlock(_ r: Int) -> CommandBlock? {
        CommandBlockDetector.block(containingRow: r, snapshot: hSnap, isExecutable: installed)
    }
    check("a heredoc runs to its terminator",
          hereBlock(1)?.firstRow == 1 && hereBlock(1)?.lastRow == 7,
          hereBlock(1).map { "\($0.firstRow)-\($0.lastRow)" } ?? "nil")
    check("a blank line inside the body does not end it",
          hereBlock(6)?.firstRow == 1 && hereBlock(6)?.lastRow == 7)
    check("pointing anywhere in the body finds the same command",
          hereBlock(4)?.text == hereBlock(1)?.text)
    check("the terminator is copied, at column 0 where a shell needs it",
          hereBlock(1)?.text.hasSuffix("\nEOF") == true,
          hereBlock(1).map { String($0.text.suffix(18)).debugDescription } ?? "nil")
    check("the body keeps its own indentation",
          hereBlock(1)?.text.contains("\n  name: stripe-api") == true)
    check("what the command printed is not part of it",
          hereBlock(1)?.text.contains("configured") == false)
    check("and that output line is not a target of its own",
          hereBlock(8) == nil)

    // A TUI that runs commands for you echoes them behind a marker. Claude
    // Code's bash mode uses `!`, and `!` pasted into an interactive shell is
    // history expansion rather than the command that was on screen.
    check("a bash-mode bang is a prompt",
          CommandBlockDetector.strippingPrompt("! ssh host uptime") == "ssh host uptime")
    check("and the command behind it is judged, not the bang",
          CommandBlockDetector.looksLikeCommand("! ssh host uptime",
                                                isExecutable: { $0 == "ssh" }))

    let (bang, feedBang) = buffer(cols: 80, rows: 8)
    feedBang("! ssh ovhprod-001 'kubectl -n snuggery get pvc -o jsonpath=\"{.a} {.b}\"'\r\n")
    feedBang("2026-09-23T10:02:11Z [kubernetes.io/pvc-protection]\r\n")
    let bangSnap = bang.snapshot()
    let bangBlock = CommandBlockDetector.block(containingRow: 0, snapshot: bangSnap,
                                               isExecutable: { $0 == "ssh" })
    check("the bang is not copied with the command",
          bangBlock?.text.hasPrefix("ssh ovhprod-001") == true,
          bangBlock.map { String($0.text.prefix(24)).debugDescription } ?? "nil")
    check("and what it printed is not either",
          bangBlock?.text.contains("pvc-protection") == false)
    check("braces inside a single-quoted argument do not leave it unfinished",
          !CommandBlockDetector.isIncomplete(
            "ssh h 'kubectl -o jsonpath=\"{.a} {.b}\"; echo'"))

    // `at`, `test`, `time`, `make`, `find`, `date` are English words as well as
    // commands, so a wrapped sentence can open with one. Inside a paragraph the
    // name proves nothing; at the start of a block it is all there is to go on.
    let isAt: (String) -> Bool = { $0 == "at" }
    check("an English word that is also a command is not one mid-paragraph",
          !CommandBlockDetector.looksLikeCommand(
            "at ssh. The bang is how Claude Code showed the command it ran",
            isExecutable: isAt, requiringSyntax: true))
    check("the same name opening a block still counts",
          CommandBlockDetector.looksLikeCommand("at 09:00 tomorrow", isExecutable: isAt))
    check("and mid-paragraph it counts once there is shell in the line",
          CommandBlockDetector.looksLikeCommand("at -f job.sh 09:00",
                                                isExecutable: isAt, requiringSyntax: true))

    let (prose, feedProse) = buffer(cols: 78, rows: 6)
    feedProse("  ⌘-hover the command: it tints even though it wrapped, and the copy starts\r\n")
    feedProse("  at ssh. The bang is how Claude Code showed the command it ran.\r\n")
    check("a wrapped note is not a command block",
          CommandBlockDetector.block(containingRow: 1, snapshot: prose.snapshot(),
                                     isExecutable: isAt) == nil)
}

print("\n\(failures == 0 ? "all checks passed" : "\(failures) check(s) FAILED")")
exit(failures == 0 ? 0 : 1)
