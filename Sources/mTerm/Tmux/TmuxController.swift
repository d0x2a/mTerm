import Foundation

/// What a `TmuxController` needs from the window it lives in.
///
/// A protocol rather than a direct reference so the mapping logic can be
/// driven without a window — see `scripts/statecheck.sh`, which replays a
/// captured session through it and asserts on the tabs it asks for.
/// Where control-mode commands go: the tab running `tmux -CC`.
///
/// A protocol rather than `Session` so the controller can be driven by a stub
/// that records what it was asked to send.
protocol TmuxCommandSink: AnyObject {
    func sendTmuxCommand(_ command: String)
}

/// A grid that a tmux window's output goes into. `Session` is the real one;
/// the tests use a recorder.
protocol TmuxPaneSink: AnyObject {
    func receive(_ bytes: [UInt8])
    func transportClosed()
}

protocol TmuxControllerHost: AnyObject {
    /// Make a tab for a tmux window and return the grid to feed it.
    func tmuxOpenTab(windowID: String, title: String) -> TmuxPaneSink
    func tmuxCloseTab(windowID: String)
    func tmuxSetTabTitle(windowID: String, title: String)
    func tmuxSelectTab(windowID: String)
    /// Every tmux tab is gone; the controlling tab goes back to being an
    /// ordinary terminal.
    func tmuxDidEnd()
}

/// Owns one `tmux -CC` connection and the tabs its windows appear in.
///
/// **Panes.** mTerm has no splits, so a tmux window's tab shows its *active*
/// pane and follows `%window-pane-changed` when tmux moves. Splitting inside
/// tmux still works and tmux's own keys still move between panes; you see one
/// at a time, filling the tab. Compositing panes from `%layout-change` would
/// mean building split rendering into the Metal view, which SPEC lists as an
/// explicit non-goal.
///
/// Main-thread only. Events arrive there already, marshalled by `Session`.
///
/// It knows nothing about sessions, views or windows — only window ids, pane
/// ids and where bytes go. That is what lets `statecheck` replay a captured
/// tmux session through it and assert on the tabs it asks for and the commands
/// it sends, with no app around it.
final class TmuxController {
    private unowned let host: TmuxControllerHost
    /// The tab running `tmux -CC` itself. Commands go out through it.
    private weak var commands: TmuxCommandSink?

    private struct Window {
        let id: String
        var title: String
        /// The pane whose output this tab shows. Unknown until tmux says.
        var activePane: String?
        let sink: TmuxPaneSink
    }
    private var windows: [String: Window] = [:]
    /// Panes whose window we haven't been told about yet. tmux sends output
    /// for a new window's pane before `list-panes` can answer, and dropping it
    /// loses the shell's first prompt.
    private var orphanedOutput: [String: [UInt8]] = [:]
    /// pane -> window, learned from `list-panes`.
    private var windowForPane: [String: String] = [:]

    /// Replies identify themselves, because neither of the other two options
    /// works.
    ///
    /// Matching on the shape of the lines lets any reply containing an
    /// `@`-prefixed line invent a window. Counting replies in order looks
    /// right — tmux answers one block per command, in order — but it is not:
    /// tmux emits an unsolicited `%begin`/`%end` block on attach, before any
    /// command has been sent, which shifts the whole queue by one and had
    /// `list-windows` output being read as a pane list.
    ///
    /// So the format strings carry a literal tag. A line that begins with one
    /// came from the command that asked for it and from nothing else, whatever
    /// order it arrives in.
    private static let windowTag = "mtermW"
    private static let paneTag = "mtermP"

    private(set) var isActive = false

    /// Grid the tmux client is told to use. tmux sizes its windows to the
    /// client, so this is the controlling tab's geometry.
    private var clientCols = 80
    private var clientRows = 24

    init(host: TmuxControllerHost, commands: TmuxCommandSink) {
        self.host = host
        self.commands = commands
    }

    // MARK: lifecycle

    func start(cols: Int, rows: Int) {
        isActive = true
        clientCols = cols
        clientRows = rows
        // tmux sizes windows to the attached client, and a control-mode client
        // has no size of its own until it is given one.
        send("refresh-client -C \(cols)x\(rows)")
        // Ask for the window list rather than waiting to be told: attaching to
        // an existing session emits %window-add only for what changes, so the
        // windows that were already there would never appear.
        send("list-windows -F '\(Self.windowTag) #{window_id} #{window_name}'")
        send("list-panes -a -F '\(Self.paneTag) #{window_id} #{pane_id} #{?pane_active,active,}'")
    }

    func end() {
        guard isActive else { return }
        isActive = false
        for (_, window) in windows { window.sink.transportClosed() }
        let ids = Array(windows.keys)
        windows.removeAll()
        windowForPane.removeAll()
        orphanedOutput.removeAll()
        for id in ids { host.tmuxCloseTab(windowID: id) }
        host.tmuxDidEnd()
    }

    // MARK: events

    func handle(_ event: TmuxEvent) {
        guard isActive || event == .sessionsChanged else { return }
        switch event {
        case .output(let pane, let bytes):
            deliver(pane: pane, bytes: bytes)

        case .windowAdd(let id):
            openWindow(id: id, title: id)
            // A new window's panes aren't in any list we've asked for yet.
            send("list-panes -t \(id) -F '\(Self.paneTag) #{window_id} #{pane_id} #{?pane_active,active,}'")

        case .windowClose(let id):
            closeWindow(id: id)

        case .windowRenamed(let id, let name):
            rename(id: id, to: name)

        case .windowPaneChanged(let id, let pane):
            setActivePane(pane, of: id)

        case .sessionWindowChanged(_, let id):
            // tmux moved to another window; follow it, so the tab that is
            // selected here is the one tmux thinks is current.
            if windows[id] != nil { host.tmuxSelectTab(windowID: id) }

        case .exit:
            end()

        case .reply(_, let lines, let error):
            guard !error else { return }
            absorb(lines)

        case .layoutChange, .sessionChanged, .sessionsChanged, .other:
            break
        }
    }

    /// Tagged lines out of any reply block. An untagged line is somebody
    /// else's business, including tmux's own attach block.
    private func absorb(_ lines: [String]) {
        for line in lines {
            let fields = line.split(separator: " ", maxSplits: 3).map(String.init)
            guard let tag = fields.first else { continue }
            switch tag {
            case Self.windowTag:
                // mtermW <window-id> <window-name>
                guard fields.count >= 2, fields[1].hasPrefix("@") else { continue }
                openWindow(id: fields[1],
                           title: fields.count >= 3 ? fields[2...].joined(separator: " ")
                                                    : fields[1])
            case Self.paneTag:
                // mtermP <window-id> <pane-id> [active]
                guard fields.count >= 3,
                      fields[1].hasPrefix("@"), fields[2].hasPrefix("%")
                else { continue }
                let windowID = fields[1], pane = fields[2]
                windowForPane[pane] = windowID
                if windows[windowID] == nil { openWindow(id: windowID, title: windowID) }
                // A window tmux hasn't marked adopts the first pane listed, so
                // a tab is never left showing nothing.
                let isActive = fields.count >= 4 && fields[3] == "active"
                if isActive || windows[windowID]?.activePane == nil {
                    setActivePane(pane, of: windowID)
                }
            default:
                continue
            }
        }
    }

    // MARK: windows

    private func rename(id: String, to name: String) {
        guard var window = windows[id], window.title != name else { return }
        window.title = name
        windows[id] = window
        host.tmuxSetTabTitle(windowID: id, title: name)
    }

    private func openWindow(id: String, title: String) {
        if windows[id] != nil {
            // Already open, and a real name still has to land: on attach
            // `%window-add @0` arrives before the `list-windows` reply, so the
            // window is created with its id as a placeholder and the name from
            // the list comes second. Guarding that out left every restored tab
            // titled "@0". The placeholder itself must not overwrite a name
            // that has since arrived, hence the `title != id`.
            if title != id { rename(id: id, to: title) }
            return
        }
        let sink = host.tmuxOpenTab(windowID: id, title: title)
        windows[id] = Window(id: id, title: title, activePane: nil, sink: sink)
        host.tmuxSetTabTitle(windowID: id, title: title)
    }

    private func closeWindow(id: String) {
        guard let window = windows.removeValue(forKey: id) else { return }
        windowForPane = windowForPane.filter { $0.value != id }
        window.sink.transportClosed()
        host.tmuxCloseTab(windowID: id)
        // The last tmux window closing is the session ending, and tmux will
        // follow with %exit — but the tabs should go now rather than linger.
        if windows.isEmpty && isActive { end() }
    }

    private func setActivePane(_ pane: String, of windowID: String) {
        windowForPane[pane] = windowID
        guard var window = windows[windowID] else { return }
        guard window.activePane != pane else { return }
        window.activePane = pane
        windows[windowID] = window
        // Whatever this pane produced before we knew where it belonged.
        if let buffered = orphanedOutput.removeValue(forKey: pane) {
            window.sink.receive(buffered)
        }
        // Note what a tab does *not* get: the pane's existing contents. tmux
        // sends %output as it happens and does not replay on request, so a tab
        // that switches to a pane starts from whatever arrives next until the
        // program in it repaints. Filling it in means `capture-pane -p -e -J`
        // and feeding the reply, which is worth doing and isn't done here.
    }

    private func deliver(pane: String, bytes: [UInt8]) {
        guard let windowID = windowForPane[pane], let window = windows[windowID] else {
            // Output for a pane we haven't placed yet. Held rather than
            // dropped: this is where a new window's first prompt lives.
            orphanedOutput[pane, default: []].append(contentsOf: bytes)
            if orphanedOutput[pane]!.count > 1 << 20 { orphanedOutput[pane] = [] }
            return
        }
        // Only the pane the tab is showing. Another pane's output is tmux's to
        // keep; when the user switches to it, tmux repaints.
        guard window.activePane == pane else { return }
        window.sink.receive(bytes)
    }

    // MARK: commands out

    func newWindow() {
        send("new-window")
    }

    func killWindow(id: String) {
        send("kill-window -t \(id)")
    }

    func selectWindow(id: String) {
        send("select-window -t \(id)")
    }

    private func send(_ command: String) {
        commands?.sendTmuxCommand(command)
    }

    // MARK: input

    /// Keystrokes for the pane a window's tab is showing.
    func sendKeys(window id: String, bytes: [UInt8]) {
        guard let pane = windows[id]?.activePane, !bytes.isEmpty else { return }
        // Hex, so nothing in the byte stream has to survive tmux's own
        // quoting — a literal would have to escape quotes, semicolons and
        // backslashes, and get every one right.
        send("send-keys -t \(pane) -H \(TmuxControlClient.hexKeys(bytes))")
    }

    /// Every tmux window is sized to the attached client, so the client is
    /// what gets resized — resizing one window would fight tmux's own layout.
    func setClientSize(cols: Int, rows: Int) {
        guard cols != clientCols || rows != clientRows else { return }
        clientCols = cols
        clientRows = rows
        send("refresh-client -C \(cols)x\(rows)")
    }

    /// Which window a tab is showing, for callers that hold the id.
    func hasWindow(_ id: String) -> Bool { windows[id] != nil }
}
