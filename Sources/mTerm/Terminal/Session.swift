import Darwin
import Foundation

final class Session {
    private let pty: Pty
    private let parser = Parser()
    private let state: TerminalState

    private let queue = DispatchQueue(label: "mterm.session", qos: .userInteractive)
    private var readSource: DispatchSourceRead?

    /// Called on the main thread when the PTY hits EOF or read errors out
    /// (i.e. the child shell process has exited).
    var onChildExit: (() -> Void)?

    /// Called on the main thread when the child rings the terminal bell.
    var onBell: (() -> Void)?

    /// Called on the main thread for an OSC 9 / OSC 777 notification escape.
    /// `title` is empty when the escape carried only a body (OSC 9).
    var onNotify: ((_ title: String, _ body: String) -> Void)?

    init?(cols: Int, rows: Int, cwd: String? = nil) {
        guard let pty = Pty.spawnShell(cols: cols, rows: rows, cwd: cwd) else { return nil }
        self.pty = pty
        self.state = TerminalState(cols: cols, rows: rows)
        self.parser.sink = state
        // TerminalState fires these on the session queue; hop to the main
        // thread so UI (focus checks, posting banners) is safe.
        state.onBell = { [weak self] in
            DispatchQueue.main.async { self?.onBell?() }
        }
        state.onNotify = { [weak self] title, body in
            DispatchQueue.main.async { self?.onNotify?(title, body) }
        }
        startReadLoop()
    }

    deinit {
        readSource?.cancel()
    }

    func snapshot(scrollOffset: Int = 0) -> TerminalSnapshot {
        queue.sync { state.viewportSnapshot(scrollOffset: scrollOffset) }
    }

    var currentDirectory: String? {
        queue.sync { state.currentDirectory }
    }

    /// See Pty.foregroundProcess(). Called from the main thread on close.
    func foregroundProcess() -> (pid: pid_t, name: String)? {
        pty.foregroundProcess()
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
            self?.state.applyThemeChange(from: old, to: new)
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
        pty.write(bytes)
    }

    func resize(cols: Int, rows: Int) {
        queue.async { [weak self] in
            self?.state.resize(cols: cols, rows: rows)
        }
        pty.resize(cols: cols, rows: rows)
    }

    private func startReadLoop() {
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

    private func drain() {
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
