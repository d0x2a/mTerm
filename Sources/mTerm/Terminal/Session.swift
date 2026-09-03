import Darwin
import Foundation

/// Where a session's bytes go when it has no PTY of its own.
///
/// A tab showing a tmux window has no child process: its output arrives as
/// `%output` on another tab's control connection, and its input has to leave
/// the same way. Everything else about the session — the parser, the grid,
/// scrollback, search, selection — is unchanged, which is the point of putting
/// the seam here rather than making the view care.
protocol SessionTransport: AnyObject {
    func sessionWrite(_ bytes: [UInt8], from session: Session)
    func sessionResize(cols: Int, rows: Int, from session: Session)
}

final class Session: TmuxCommandSink, TmuxPaneSink {
    /// nil for a tmux-backed session, which has a transport instead.
    private let pty: Pty?
    /// Set for a tmux-backed session. Weak: the controller owns the tabs that
    /// own these sessions.
    private weak var transport: SessionTransport?
    private let parser = Parser()
    private let state: TerminalState

    private let queue = DispatchQueue(label: "mterm.session", qos: .userInteractive)
    private var readSource: DispatchSourceRead?

    /// Called on the main thread when the PTY hits EOF or read errors out
    /// (i.e. the child shell process has exited).
    var onChildExit: (() -> Void)?

    /// Called on the main thread once the child has produced output. Lets the
    /// view present as soon as bytes land instead of polling for them: the
    /// display link and key handling share the main run loop, so an echo
    /// consistently just missed the frame being drawn and waited out most of
    /// the next one.
    var onOutput: (() -> Void)?
    private let signalLock = NSLock()
    private var outputSignalPending = false

    /// The bottom-of-buffer view as of the last change, republished by the
    /// session queue. The main thread reads it without touching that queue.
    ///
    /// `drain()` holds the queue for a whole burst of output — milliseconds at
    /// a time — and every frame used to block on it to take a snapshot, and
    /// every tick to ask whether a synchronized update was open. So while the
    /// child was writing, the main thread spent most of its time waiting, which
    /// is what made typing during a build feel sticky. Nothing else mutates the
    /// state, so between bursts this is exactly what the queue would have
    /// returned; during one, the view draws the previous frame's contents
    /// instead of stalling, and the burst's own signal brings it up to date.
    private struct Published {
        let snapshot: TerminalSnapshot
        /// The deadline rather than a sampled Bool, so the gate can close on
        /// a tick this queue never woke for. See
        /// `TerminalState.synchronizedUpdateDeadline`.
        let synchronizedUpdateDeadline: CFAbsoluteTime?

        var synchronizedUpdateActive: Bool {
            guard let deadline = synchronizedUpdateDeadline else { return false }
            return CFAbsoluteTimeGetCurrent() < deadline
        }
    }
    private let publishedLock = NSLock()
    private var published: Published?

    /// Called on the main thread when the child rings the terminal bell.
    var onBell: (() -> Void)?

    /// Called on the main thread for an OSC 9 / OSC 777 notification escape.
    /// `title` is empty when the escape carried only a body (OSC 9).
    var onNotify: ((_ title: String, _ body: String) -> Void)?

    /// Control-mode events, on the main thread and in stream order, once the
    /// child in this tab has run `tmux -CC`. The bytes are parsed on the
    /// session queue; only the events cross over.
    var onTmuxEvent: ((TmuxEvent) -> Void)?
    /// Live only while the child holds control mode open.
    private var tmuxClient: TmuxControlClient?
    var isTmuxControlActive: Bool { tmuxClient != nil }

    /// `cwd` overrides the profile's own directory — session restore hands
    /// back the tab's last one. Main-thread only, for `ProfileStore`.
    init?(cols: Int, rows: Int, cwd: String? = nil, profile: Profile? = nil,
          theme: Theme = ThemeStore.currentTheme) {
        let spec = (profile ?? ProfileStore.shared.defaultProfile).launchSpec(cwd: cwd)
        guard let pty = Pty.spawn(spec, cols: cols, rows: rows) else { return nil }
        self.pty = pty
        self.state = TerminalState(cols: cols, rows: rows, theme: theme)
        self.parser.sink = state
        // TerminalState fires these on the session queue; hop to the main
        // thread so UI (focus checks, posting banners) is safe.
        state.onBell = { [weak self] in
            DispatchQueue.main.async { self?.onBell?() }
        }
        state.onNotify = { [weak self] title, body in
            DispatchQueue.main.async { self?.onNotify?(title, body) }
        }
        // Device-attribute and cursor-position answers go straight back to the
        // child. Already on the session queue, and the PTY write is a plain
        // fd write, so there's no hop to make.
        state.onReply = { [weak pty] bytes in
            pty?.write(bytes)
        }
        // `tmux -CC` announces itself with ESC P 1000 p and then keeps that
        // string open for the whole session, streaming every pane through it.
        state.onDCSStart = { [weak self] params, final in
            guard params.first == 1000, final == UInt8(ascii: "p") else { return }
            let client = TmuxControlClient()
            client.onEvent = { [weak self] event in
                DispatchQueue.main.async { self?.onTmuxEvent?(event) }
            }
            self?.tmuxClient = client
        }
        state.onDCSPut = { [weak self] bytes in
            self?.tmuxClient?.feed(bytes)
        }
        state.onDCSEnd = { [weak self] in
            guard let self, self.tmuxClient != nil else { return }
            self.tmuxClient?.finish()
            self.tmuxClient = nil
            // tmux closes the string when it goes away, and does not always
            // get a `%exit` out first — a detach or a killed server just ends
            // it. Report one anyway, or the tabs its windows were in would be
            // left showing a session that no longer exists.
            DispatchQueue.main.async { self.onTmuxEvent?(.exit(reason: "")) }
        }
        startReadLoop()
    }

    /// A session with no child of its own, fed by `receive` and writing back
    /// through `transport`. The grid is built at the size the caller asks for
    /// and reflows the same way any other does.
    init(cols: Int, rows: Int, transport: SessionTransport,
         theme: Theme = ThemeStore.currentTheme) {
        self.pty = nil
        self.transport = transport
        self.state = TerminalState(cols: cols, rows: rows, theme: theme)
        self.parser.sink = state
        state.onBell = { [weak self] in
            DispatchQueue.main.async { self?.onBell?() }
        }
        state.onNotify = { [weak self] title, body in
            DispatchQueue.main.async { self?.onNotify?(title, body) }
        }
        // Device reports go back to tmux, which forwards them to the program
        // in the pane — it queried the terminal and is waiting for an answer.
        state.onReply = { [weak self] bytes in
            guard let self else { return }
            DispatchQueue.main.async { self.transport?.sessionWrite(bytes, from: self) }
        }
    }

    /// Bytes for this session's grid, from wherever its transport got them.
    /// Parsed on the session queue like a PTY read, so nothing races.
    func receive(_ bytes: [UInt8]) {
        queue.async { [weak self] in
            guard let self else { return }
            bytes.withUnsafeBufferPointer { self.parser.feed(bytes: $0) }
            self.publish()
            self.signalOutput()
        }
    }

    /// Ends a tmux-backed session, the way EOF ends a PTY-backed one.
    func transportClosed() {
        notifyChildExit()
    }

    deinit {
        readSource?.cancel()
    }

    /// Must run on `queue`.
    private func publish() {
        let value = Published(snapshot: state.viewportSnapshot(scrollOffset: 0),
                              synchronizedUpdateDeadline: state.synchronizedUpdateDeadline)
        publishedLock.lock()
        published = value
        publishedLock.unlock()
    }

    /// Drops the published view so the next read falls back to the queue, which
    /// is FIFO behind the change that is about to be enqueued. Used where a
    /// frame drawn from the previous state would be visibly wrong rather than
    /// merely a beat behind — a resize, where it would have the old geometry.
    private func invalidatePublished() {
        publishedLock.lock()
        published = nil
        publishedLock.unlock()
    }

    private var publishedValue: Published? {
        publishedLock.lock()
        defer { publishedLock.unlock() }
        return published
    }

    func snapshot(scrollOffset: Int = 0) -> TerminalSnapshot {
        // Scrolled back, the viewport has to be composed out of history, which
        // only the queue can do. Typing snaps to the bottom, so the path that
        // has to stay quick is always offset 0.
        if scrollOffset == 0, let value = publishedValue { return value.snapshot }
        return queue.sync { state.viewportSnapshot(scrollOffset: scrollOffset) }
    }

    /// The modes the view has to honor, fetched in one hop so a mouse event
    /// doesn't take four trips onto the session queue.
    struct InputModes {
        let bracketedPaste: Bool
        let reportFocus: Bool
        let mouseTracking: MouseTracking
        let mouseEncoding: MouseEncoding
        let alternateScroll: Bool
        let usingAltScreen: Bool
    }

    var inputModes: InputModes {
        queue.sync {
            InputModes(bracketedPaste: state.bracketedPaste,
                       reportFocus: state.reportFocus,
                       mouseTracking: state.mouseTracking,
                       mouseEncoding: state.mouseEncoding,
                       alternateScroll: state.alternateScroll,
                       usingAltScreen: state.usingAlt)
        }
    }

    /// The grid and the synchronized-update flag (DEC 2026) as of one publish,
    /// read in a single lock acquisition. While the flag is set the view holds
    /// the last frame instead of presenting this one.
    ///
    /// They have to come from the same publish. Asking for them separately let
    /// the session queue swap `published` in between, so the view could clear
    /// the gate against a finished frame and then draw the *next* one — taken
    /// mid-redraw, with the child's erase applied and its repaint still to
    /// come. That renders as a flash of half-drawn screen.
    func publishedFrame(scrollOffset: Int) -> (snapshot: TerminalSnapshot,
                                               synchronizedUpdateActive: Bool) {
        if scrollOffset == 0, let value = publishedValue {
            return (value.snapshot, value.synchronizedUpdateActive)
        }
        return queue.sync {
            (state.viewportSnapshot(scrollOffset: scrollOffset),
             state.synchronizedUpdateActive)
        }
    }

    /// Whole-buffer text (scrollback + active grid) for "Copy All".
    func bufferText() -> String {
        queue.sync { state.bufferText() }
    }

    /// Absolute-line bounds of everything the buffer holds, for "Select All".
    func contentBounds() -> (firstLine: Int, lastLine: Int, lastCol: Int)? {
        queue.sync { state.contentBounds() }
    }

    /// Text for a selection, in absolute line numbers so it can span scrollback.
    func selectionText(from startLine: Int, startCol: Int,
                       to endLine: Int, endCol: Int) -> String {
        queue.sync {
            state.text(from: startLine, startCol: startCol, to: endLine, endCol: endCol)
        }
    }

    var currentDirectory: String? {
        queue.sync { state.currentDirectory }
    }

    /// See Pty.foregroundProcess(). Called from the main thread on close.
    func foregroundProcess() -> (pid: pid_t, name: String)? {
        // A tmux-backed tab has no child of its own to ask about. What runs in
        // the pane is tmux's business, and closing the tab closes a tmux
        // window rather than killing anything of ours — so there is nothing to
        // warn about on close.
        pty?.foregroundProcess()
    }

    /// Returns a new scrollOffset that jumps to the nearest prompt above
    /// (direction < 0) or below (direction > 0) the current viewport. Returns
    /// nil if nothing to jump to.
    func jumpToPrompt(direction: Int, from currentOffset: Int) -> Int? {
        queue.sync { state.jumpToPromptOffset(direction: direction, from: currentOffset) }
    }

    /// Remaps any baked-in cell colors from the old theme to the new theme.
    /// Runs on the session queue so it doesn't race with the parser.
    func applyThemeChange(from old: Theme, to new: Theme) {
        queue.async { [weak self] in
            guard let self else { return }
            self.state.applyThemeChange(from: old, to: new)
            self.publish()
        }
    }

    /// Runs a scrollback search. Smart-case: query containing any uppercase
    /// letter triggers case-sensitive matching.
    func search(query: String, regex: Bool) -> [SearchMatch] {
        let caseSensitive = query.contains { $0.isUppercase }
        return queue.sync {
            state.search(query: query, regex: regex, caseSensitive: caseSensitive)
        }
    }

    func write(_ bytes: [UInt8]) {
        if let pty {
            pty.write(bytes)
        } else {
            transport?.sessionWrite(bytes, from: self)
        }
    }

    /// Sends one control-mode command to the tmux running in this tab.
    func sendTmuxCommand(_ command: String) {
        guard tmuxClient != nil else { return }
        write(Array((command + "\n").utf8))
    }

    func resize(cols: Int, rows: Int) {
        // A frame drawn between here and the reflow would carry the old
        // geometry, so make readers wait on the queue until it lands.
        invalidatePublished()
        queue.async { [weak self] in
            guard let self else { return }
            self.state.resize(cols: cols, rows: rows)
            self.publish()
        }
        if let pty {
            pty.resize(cols: cols, rows: rows)
        } else {
            transport?.sessionResize(cols: cols, rows: rows, from: self)
        }
    }

    private func startReadLoop() {
        guard let pty else { return }
        let src = DispatchSource.makeReadSource(fileDescriptor: pty.masterFd, queue: queue)
        src.setEventHandler { [weak self] in
            self?.drain()
        }
        src.resume()
        readSource = src
    }

    private var didNotifyExit = false

    private func notifyChildExit() {
        guard !didNotifyExit else { return }
        didNotifyExit = true
        DispatchQueue.main.async { [weak self] in
            self?.onChildExit?()
        }
    }

    /// Coalesced hop to the main thread: one pending signal at a time, so a
    /// burst of reads can't flood the main queue with redundant wake-ups.
    private func signalOutput() {
        signalLock.lock()
        if outputSignalPending { signalLock.unlock(); return }
        outputSignalPending = true
        signalLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.signalLock.lock()
            self.outputSignalPending = false
            self.signalLock.unlock()
            self.onOutput?()
        }
    }

    /// How long this loop may go without publishing what it has parsed.
    /// Roughly a frame at 120 Hz.
    private static let publishInterval: UInt64 = 8_000_000   // ns

    private func drain() {
        guard let pty else { return }
        var produced = false
        defer { if produced { publish(); signalOutput() } }
        var lastPublish = DispatchTime.now().uptimeNanoseconds
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr in
                read(pty.masterFd, ptr.baseAddress, ptr.count)
            }
            if n > 0 {
                buf.withUnsafeBufferPointer { ptr in
                    let slice = UnsafeBufferPointer(start: ptr.baseAddress, count: Int(n))
                    parser.feed(bytes: slice)
                }
                produced = true
                // This loop runs until the writer pauses, which under something
                // like `cat` on a large file is seconds. Publishing only on the
                // way out would leave the view redrawing the pre-burst frame for
                // that whole time, so hand it a fresh one as we go.
                let now = DispatchTime.now().uptimeNanoseconds
                if now &- lastPublish >= Self.publishInterval {
                    lastPublish = now
                    publish()
                    signalOutput()
                }
            } else if n == 0 {
                readSource?.cancel()
                notifyChildExit()
                return
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
                readSource?.cancel()
                notifyChildExit()
                return
            }
        }
    }
}
