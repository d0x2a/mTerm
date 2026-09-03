// Drives a real `tmux -CC` over a real pty through the exact chain the app
// uses — Parser -> TerminalState's DCS callbacks -> TmuxControlClient ->
// TmuxController — with a recording host standing in for the window.
// Everything but the AppKit layer, against the real protocol rather than a
// fixture.
//
// Worth having because this is where the protocol's surprises live. It caught
// two: tmux emits an unsolicited %begin/%end block on attach, which shifted a
// positional reply queue by one; and %window-add arrives before the
// list-windows reply, so a window is created with its id as a placeholder and
// named a moment later — tabs were all called "@0".
//
// Uses its own tmux socket and kills it on the way out, so it cannot touch a
// session anyone is using. Run it with scripts/tmuxcheck.sh.

import AppKit
import Darwin
import Foundation

_ = NSApplication.shared
_ = ThemeStore.shared

let socket = "mtermcheck"

var failures = 0
func check(_ n: String, _ c: Bool, _ d: String = "") {
    print("\(c ? "  ok  " : "  FAIL") \(n)\(d.isEmpty ? "" : "  — \(d)")")
    if !c { failures += 1 }
}

final class Sink: TmuxPaneSink {
    var bytes: [UInt8] = []
    var closed = false
    func receive(_ b: [UInt8]) { bytes.append(contentsOf: b) }
    func transportClosed() { closed = true }
    var text: String { String(decoding: bytes, as: UTF8.self) }
}

final class Host: TmuxControllerHost, TmuxCommandSink {
    var sinks: [String: Sink] = [:]
    var opened: [String] = []
    var closed: [String] = []
    var titles: [String: String] = [:]
    var ended = false
    var write: ((String) -> Void)?
    func tmuxOpenTab(windowID: String, title: String,
                     cols: Int, rows: Int) -> TmuxPaneSink {
        let s = Sink(); sinks[windowID] = s; opened.append(windowID); return s
    }
    func tmuxCloseTab(windowID: String) { closed.append(windowID) }
    func tmuxSetTabTitle(windowID: String, title: String) { titles[windowID] = title }
    func tmuxSelectTab(windowID: String) {}
    func tmuxDidEnd() { ended = true }
    var commands: [String] = []
    func sendTmuxCommand(_ command: String) {
        commands.append(command)
            write?(command + "\n")
    }
}

// MARK: spawn a real tmux -CC on a pty

// A second session on the same server, detached and nothing to do with us.
// Its windows must not become tabs: `list-panes -a` listed every pane on the
// *server*, so one of them did — titled with its raw id, because list-windows
// (correctly scoped to the session) never named it.
let seed = Process()
seed.executableURL = URL(fileURLWithPath: "/usr/bin/env")
seed.arguments = ["tmux", "-L", socket, "-f", "/dev/null",
                  "new-session", "-d", "-s", "bystander"]
try? seed.run()
seed.waitUntilExit()

var master: Int32 = 0
var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
let pid = forkpty(&master, nil, nil, &size)
if pid == 0 {
    unsetenv("TMUX")
    let args = ["tmux", "-L", socket, "-f", "/dev/null",
                "-CC", "new-session", "-x", "80", "-y", "24"]
    var cargs = args.map { strdup($0) }
    cargs.append(nil)
    execvp("tmux", &cargs)
    _exit(1)
}

var log: [String] = []
let host = Host()
let controller = TmuxController(host: host, commands: host)
// Commands are queued, not written from inside the parse path. Writing
// synchronously there deadlocks: the controller sends from an event handler,
// which runs inside `pump`, so when tmux blocks writing output that nobody is
// draining, our write blocks too and neither side moves — the stream stopped
// dead mid-reply. `Pty.write` flushes on its own queue for exactly this
// reason; the harness has to alternate reading and writing by hand.
var outbox: [UInt8] = []
host.write = { command in outbox.append(contentsOf: Array(command.utf8)) }

func flushOutbox() {
    while !outbox.isEmpty {
        var p = pollfd(fd: master, events: Int16(POLLOUT), revents: 0)
        guard poll(&p, 1, 0) > 0 else { return }        // not writable; try later
        let n = outbox.withUnsafeBufferPointer { write(master, $0.baseAddress, $0.count) }
        guard n > 0 else { return }
        outbox.removeFirst(n)
    }
}

// The chain, wired exactly as Session wires it.
let state = TerminalState(cols: 80, rows: 24)
let parser = Parser()
parser.sink = state
var client: TmuxControlClient?
state.onDCSStart = { params, final in
    guard params.first == 1000, final == UInt8(ascii: "p") else { return }
    let c = TmuxControlClient()
    c.onEvent = { event in
        switch event {
        case .output: break
        default: log.append("\(event)")
        }
        controller.handle(event)
    }
    client = c
    controller.start(cols: 80, rows: 24)
}
state.onDCSPut = { client?.feed($0) }
state.onDCSEnd = { client?.finish(); client = nil }

func pump(_ seconds: Double) {
    var buf = [UInt8](repeating: 0, count: 8192)
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        flushOutbox()
        var fds = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
        guard poll(&fds, 1, 100) > 0 else { continue }
        let n = buf.withUnsafeMutableBufferPointer { read(master, $0.baseAddress, $0.count) }
        guard n > 0 else { break }
        buf.withUnsafeBufferPointer {
            parser.feed(bytes: UnsafeBufferPointer(start: $0.baseAddress, count: n))
        }
    }
}

print("-- attach --")
pump(3.0)
check("control mode was detected", client != nil,
      "the DCS never reached the client")
check("exactly one tab, for our own session's window", host.opened.count == 1,
      "opened \(host.opened) — an extra entry is the bystander session's")
let firstWindow = host.opened.first ?? "@0"
let first = host.sinks[firstWindow]
check("and the shell's prompt reached that tab's grid",
      (first?.bytes.count ?? 0) > 0,
      "\(first?.bytes.count ?? 0) bytes")

print("-- new-window --")
controller.newWindow()
pump(2.5)
check("new-window opens a second tab", host.opened.count == 2,
      "opened \(host.opened)")
check("its title came from tmux", host.titles[host.opened.last ?? ""] != nil,
      "titles \(host.titles)")
let second = host.sinks[host.opened.last ?? ""]
check("and its pane's first output was not lost",
      (second?.bytes.count ?? 0) > 0,
      "\(second?.bytes.count ?? 0) bytes — this is the orphaned-output path")

print("-- typing --")
let target = host.opened.last!
controller.sendKeys(window: target, bytes: Array("echo mterm-e2e\r".utf8))
pump(2.5)
check("keystrokes reach the pane and its output comes back",
      second?.text.contains("mterm-e2e") == true,
      "tab shows: \(String((second?.text ?? "").suffix(120)).debugDescription)")

print("-- resize --")
// tmux answers a resize with %layout-change and does *not* resend the pane, so
// a control-mode client has to ask. Without this the grid keeps the pre-resize
// screen and whatever the program doesn't repaint stays stale — the top border
// of Claude Code's input box came back as a two-character stub.
host.commands = []
controller.setClientSize(cols: 100, rows: 30)
pump(5.0)
check("a resize asks tmux for the pane's contents",
      host.commands.contains { $0.hasPrefix("capture-pane -p -t") },
      "commands: \(host.commands)")
check("and never with -e, which would end the control-mode DCS",
      !host.commands.contains { $0.contains("capture-pane") && $0.contains("-e") },
      "capture-pane -e returns raw ESC bytes; control mode is one long DCS")
// The stream surviving is the real assertion: an ESC in a reply used to end
// the DCS, after which every notification below was parsed as terminal output.
check("the marker carries the cursor, which the capture omits",
      host.commands.contains { $0.contains("#{cursor_x}") && $0.contains("#{cursor_y}") },
      "without it the repaint leaves the cursor at the bottom and the next newline scrolls")
check("and the control stream is still alive afterwards",
      host.commands.contains { $0.hasPrefix("display-message") },
      "the marker that claims the capture never went out")

print("-- close a window --")
controller.killWindow(id: target)
pump(5.0)
check("closing a tmux window closes its tab", host.closed.contains(target),
      "closed \(host.closed)")

print("-- exit --")
host.sendTmuxCommand("kill-session")
pump(5.0)
check("killing the session ends control mode", host.ended)
check("and the remaining tab was closed", host.closed.contains(firstWindow),
      "closed \(host.closed)")

if failures > 0 {
    print("\n-- events seen (output elided) --")
    for line in log { print("   ", line.prefix(120)) }
}
// Leave no server and no socket behind.
let cleanup = Process()
cleanup.executableURL = URL(fileURLWithPath: "/usr/bin/env")
cleanup.arguments = ["tmux", "-L", socket, "kill-server"]
try? cleanup.run()
cleanup.waitUntilExit()
kill(pid, SIGTERM)
print("\n\(failures == 0 ? "end-to-end passed" : "\(failures) FAILED")")
exit(failures == 0 ? 0 : 1)
