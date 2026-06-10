import Darwin
import Foundation
import CMTermBridge

final class Pty {
    let masterFd: Int32
    let pid: pid_t

    // All input (keystrokes + pastes) funnels through this serial queue. A
    // large paste can fill the kernel's PTY input buffer, at which point our
    // non-blocking write() returns EAGAIN; rather than dropping the rest (the
    // old truncation bug) we park it in `pending` and flush via `writeSource`
    // once the fd drains. Kept off the main thread (no UI jank) and off the
    // session read queue (blocking there would deadlock the child's output).
    private let writeQueue = DispatchQueue(label: "mterm.pty.write", qos: .userInteractive)
    private var pending = [UInt8]()
    private var pendingOffset = 0
    private var writeSource: DispatchSourceWrite?
    private var writeSourceActive = false

    private init(masterFd: Int32, pid: pid_t) {
        self.masterFd = masterFd
        self.pid = pid
    }

    deinit {
        // Releasing a suspended dispatch source crashes, so resume it (if it
        // was parked) before cancelling.
        if let src = writeSource {
            if !writeSourceActive { src.resume() }
            src.cancel()
        }
        close(masterFd)
        kill(pid, SIGHUP)
    }

    static func spawnShell(cols: Int, rows: Int, cwd: String? = nil) -> Pty? {
        setenv("TERM", "xterm-256color", 1)
        setenv("LANG", "en_US.UTF-8", 1)
        setenv("COLORTERM", "truecolor", 1)

        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        var pid: pid_t = 0
        let master: Int32 = shellPath.withCString { shellCStr in
            if let cwd = cwd, !cwd.isEmpty {
                return cwd.withCString { cwdCStr in
                    mterm_spawn_shell(shellCStr, cwdCStr, UInt16(rows), UInt16(cols), &pid)
                }
            }
            return mterm_spawn_shell(shellCStr, nil, UInt16(rows), UInt16(cols), &pid)
        }
        if master < 0 { return nil }

        let flags = fcntl(master, F_GETFL, 0)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        return Pty(masterFd: master, pid: pid)
    }

    func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        writeQueue.async { [weak self] in
            guard let self else { return }
            // Drop the already-sent prefix so the backlog doesn't grow without
            // bound across many writes.
            if self.pendingOffset > 0 {
                self.pending.removeFirst(self.pendingOffset)
                self.pendingOffset = 0
            }
            self.pending.append(contentsOf: bytes)
            self.flushPending()
        }
    }

    /// Writes as much of `pending` as the kernel will take. On EAGAIN it leaves
    /// the remainder parked and resumes `writeSource` to retry once the fd is
    /// writable again. Must run on `writeQueue`.
    private func flushPending() {
        while pendingOffset < pending.count {
            let n = pending.withUnsafeBufferPointer { ptr in
                Darwin.write(masterFd, ptr.baseAddress! + pendingOffset,
                             pending.count - pendingOffset)
            }
            if n > 0 {
                pendingOffset += n
            } else if n < 0 {
                switch errno {
                case EINTR:
                    continue
                case EAGAIN, EWOULDBLOCK:
                    resumeWriteSource()
                    return
                default:
                    // Unrecoverable (e.g. fd closed); discard the backlog.
                    pending.removeAll(keepingCapacity: false)
                    pendingOffset = 0
                    suspendWriteSource()
                    return
                }
            } else {
                return
            }
        }
        pending.removeAll(keepingCapacity: false)
        pendingOffset = 0
        suspendWriteSource()
    }

    private func resumeWriteSource() {
        if writeSource == nil {
            let src = DispatchSource.makeWriteSource(fileDescriptor: masterFd, queue: writeQueue)
            src.setEventHandler { [weak self] in self?.flushPending() }
            writeSource = src   // sources start suspended
        }
        guard !writeSourceActive else { return }
        writeSourceActive = true
        writeSource?.resume()
    }

    private func suspendWriteSource() {
        guard writeSourceActive else { return }
        writeSourceActive = false
        writeSource?.suspend()
    }

    func resize(cols: Int, rows: Int) {
        _ = mterm_set_winsize(masterFd, UInt16(rows), UInt16(cols))
    }

    /// Foreground process group running in the terminal, or nil if it's just
    /// the shell sitting at a prompt (pgid == shell pid) or the lookup failed.
    ///
    /// Detects only foreground processes — backgrounded jobs (`sleep 100 &`)
    /// don't take the controlling terminal, so they don't count. This matches
    /// iTerm2/Terminal.app's "close anyway?" behavior.
    func foregroundProcess() -> (pid: pid_t, name: String)? {
        let pgid = tcgetpgrp(masterFd)
        guard pgid > 0, pgid != pid else { return nil }

        var buf = [CChar](repeating: 0, count: 256)
        let n = buf.withUnsafeMutableBufferPointer { ptr in
            mterm_proc_name(pgid, ptr.baseAddress, Int32(ptr.count))
        }
        let name: String
        if n > 0, let s = String(validatingUTF8: buf), !s.isEmpty {
            name = s
        } else {
            // Lookup failed but the pgid is real — still report the process.
            name = "a process"
        }
        return (pgid, name)
    }
}
