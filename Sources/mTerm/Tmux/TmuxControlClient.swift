import Foundation

/// One thing tmux told us, in control mode.
enum TmuxEvent: Equatable {
    /// Output for a pane, already unescaped back to raw bytes.
    case output(pane: String, bytes: [UInt8])
    case windowAdd(window: String)
    case windowClose(window: String)
    case windowRenamed(window: String, name: String)
    /// The session's active window changed.
    case sessionWindowChanged(session: String, window: String)
    /// A window's active pane changed. This is what moves a tab from showing
    /// one pane to showing another.
    case windowPaneChanged(window: String, pane: String)
    case layoutChange(window: String, layout: String)
    case sessionChanged(session: String, name: String)
    case sessionsChanged
    /// tmux is going away. `reason` is empty when it didn't give one.
    case exit(reason: String)
    /// A reply to a command we sent, as its lines. `error` is true for
    /// `%error` rather than `%end`.
    case reply(id: Int, lines: [String], error: Bool)
    /// A notification this build doesn't act on. Kept rather than dropped so
    /// the log and the tests can see the protocol is being read whole.
    case other(name: String, arguments: String)
}

/// Parses tmux's control-mode output, which arrives as the payload of the DCS
/// that `tmux -CC` opens (`ESC P 1000 p`) and continues for the life of the
/// session.
///
/// Line-oriented and fed incrementally: the transport hands over whatever came
/// out of the PTY, which splits lines wherever it feels like.
///
/// Nothing here touches AppKit or the app — it turns bytes into `TmuxEvent`s
/// and nothing else, which is what makes it testable without a tmux running.
final class TmuxControlClient {
    /// Called for each event, in arrival order.
    var onEvent: ((TmuxEvent) -> Void)?

    private var pending: [UInt8] = []
    /// Lines gathered since `%begin`, if we're inside a reply block.
    private var block: (id: Int, lines: [String])?

    // MARK: input

    func feed(_ bytes: ArraySlice<UInt8>) {
        pending.append(contentsOf: bytes)
        // tmux terminates its lines with CRLF on a tty. Split on LF and strip
        // a trailing CR, so a CR that lands in the next chunk can't split a
        // line in two.
        while let i = pending.firstIndex(of: 0x0A) {
            var line = Array(pending[pending.startIndex..<i])
            if line.last == 0x0D { line.removeLast() }
            pending.removeSubrange(pending.startIndex...i)
            handle(line: String(decoding: line, as: UTF8.self))
        }
        // A pathological peer that never sends a newline shouldn't grow this
        // without bound. tmux's longest line is a screenful of escaped output;
        // a megabyte is far past that and far below anything that hurts.
        if pending.count > 1 << 20 { pending.removeAll(keepingCapacity: false) }
    }

    /// Anything left when the DCS closes is an unterminated line, and tmux is
    /// gone either way.
    func finish() {
        pending.removeAll()
        if let block {
            onEvent?(.reply(id: block.id, lines: block.lines, error: true))
            self.block = nil
        }
    }

    // MARK: lines

    private func handle(line: String) {
        // Inside a reply block every line is payload until the block ends —
        // including one that starts with '%', which `list-panes` output can.
        if var current = block {
            if line.hasPrefix("%end ") || line.hasPrefix("%error ") {
                block = nil
                onEvent?(.reply(id: current.id, lines: current.lines,
                                error: line.hasPrefix("%error ")))
                return
            }
            current.lines.append(line)
            block = current
            return
        }

        guard line.hasPrefix("%") else { return }
        let (name, rest) = split(line.dropFirst())

        switch name {
        case "begin":
            // "%begin <time> <number> <flags>" — the number is what ties a
            // reply to the command that asked for it.
            let parts = rest.split(separator: " ")
            block = (id: parts.count > 1 ? Int(parts[1]) ?? -1 : -1, lines: [])
        case "output":
            let (pane, data) = split(rest)
            onEvent?(.output(pane: pane, bytes: Self.unescape(data)))
        case "window-add", "unlinked-window-add":
            onEvent?(.windowAdd(window: rest))
        case "window-close", "unlinked-window-close":
            onEvent?(.windowClose(window: rest))
        case "window-renamed", "unlinked-window-renamed":
            let (window, newName) = split(rest)
            onEvent?(.windowRenamed(window: window, name: newName))
        case "session-window-changed":
            let (session, window) = split(rest)
            onEvent?(.sessionWindowChanged(session: session, window: window))
        case "window-pane-changed":
            let (window, pane) = split(rest)
            onEvent?(.windowPaneChanged(window: window, pane: pane))
        case "layout-change":
            let (window, layout) = split(rest)
            onEvent?(.layoutChange(window: window, layout: layout))
        case "session-changed":
            let (session, sessionName) = split(rest)
            onEvent?(.sessionChanged(session: session, name: sessionName))
        case "sessions-changed":
            onEvent?(.sessionsChanged)
        case "exit":
            onEvent?(.exit(reason: rest))
        default:
            onEvent?(.other(name: name, arguments: rest))
        }
    }

    /// First word, and everything after the single space that follows it.
    private func split<S: StringProtocol>(_ s: S) -> (String, String) {
        guard let space = s.firstIndex(of: " ") else { return (String(s), "") }
        return (String(s[s.startIndex..<space]), String(s[s.index(after: space)...]))
    }

    // MARK: escaping

    /// `%output` escapes non-printable bytes and backslash itself as `\ooo`,
    /// three octal digits. Everything else — UTF-8 included — is literal.
    static func unescape(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(s.utf8.count)
        var it = Array(s.utf8)[...]
        while let c = it.first {
            it = it.dropFirst()
            guard c == 0x5C else {          // '\'
                out.append(c)
                continue
            }
            // Exactly three octal digits, per the format tmux writes. A
            // backslash followed by anything else is passed through as itself
            // rather than swallowed, so a malformed line loses one character
            // instead of the rest of the screen.
            let digits = it.prefix(3)
            guard digits.count == 3, digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x37 }) else {
                out.append(c)
                continue
            }
            var value = 0
            for d in digits { value = value * 8 + Int(d - 0x30) }
            it = it.dropFirst(3)
            out.append(UInt8(truncatingIfNeeded: value))
        }
        return out
    }

    /// The inverse, for the one direction we send bytes: `send-keys -H` takes
    /// hex, which avoids every quoting question a literal would raise.
    static func hexKeys(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
