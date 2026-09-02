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

    /// Last answer from foregroundProcess(), which renderFrame asks for every
    /// frame. Resolving the group leader to the real command walks the process
    /// table (~30µs), so only redo it when the foreground group changes or the
    /// answer goes stale. Main-thread only, like its one caller.
    private var cachedForeground: (pgid: pid_t, pid: pid_t, name: String, at: CFAbsoluteTime)?
    private static let foregroundCacheTTL: CFAbsoluteTime = 0.5

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
        if reaped == nil { kill(pid, SIGHUP) }
    }

    /// Starts `spec` on a fresh PTY. Shell integration is applied here, per
    /// spawn, so a profile running bash gets bash's hooks while the zsh tab
    /// next to it keeps its own — nothing about either leaks into the app's
    /// environment or into the other tab.
    static func spawn(_ spec: LaunchSpec, cols: Int, rows: Int) -> Pty? {
        var argv = spec.argv
        var env = [
            "TERM=xterm-256color",
            "COLORTERM=truecolor",
            "TERM_PROGRAM=mTerm",
            "TERM_PROGRAM_VERSION=" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                                       as? String ?? "dev"),
        ]
        if ProcessInfo.processInfo.environment["LANG"] == nil {
            env.append("LANG=en_US.UTF-8")
        }
        if let injection = ShellIntegration.injection(path: spec.path, argv: argv) {
            argv = injection.argv
            env += injection.env
        }
        // The profile's own variables last, so they win over ours.
        env += spec.env

        var pid: pid_t = 0
        let master = withCStringArray(argv) { argvPtr in
            withCStringArray(env) { envPtr in
                spec.path.withCString { pathCStr in
                    if let cwd = spec.cwd, !cwd.isEmpty {
                        return cwd.withCString { cwdCStr in
                            mterm_spawn(pathCStr, argvPtr, cwdCStr, envPtr,
                                        UInt16(rows), UInt16(cols), &pid)
                        }
                    }
                    return mterm_spawn(pathCStr, argvPtr, nil, envPtr,
                                       UInt16(rows), UInt16(cols), &pid)
                }
            }
        }
        if master < 0 { return nil }

        let flags = fcntl(master, F_GETFL, 0)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        return Pty(masterFd: master, pid: pid)
    }

    /// A NULL-terminated `char *[]` for the duration of `body`.
    private static func withCStringArray<R>(_ strings: [String],
                                            _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { for p in pointers { free(p) } }
        return pointers.withUnsafeBufferPointer { buf in
            body(buf.baseAddress!)
        }
    }

    /// The child's exit status once it has gone, reaped here because nothing
    /// else waits on it. nil while it is still running. Main-thread only.
    func exitStatus() -> Int32? {
        if let reaped { return reaped }
        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        guard r == pid else { return nil }
        let code: Int32
        if (status & 0x7f) == 0 {
            code = (status >> 8) & 0xff              // WEXITSTATUS
        } else {
            code = 128 + (status & 0x7f)             // killed by a signal
        }
        reaped = code
        return code
    }
    private var reaped: Int32?

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

        let now = CFAbsoluteTimeGetCurrent()
        if let cached = cachedForeground,
           cached.pgid == pgid,
           now - cached.at < Self.foregroundCacheTTL {
            return (cached.pid, cached.name)
        }

        // The group leader is often only a wrapper — `codex` is an npm shim
        // whose leader is `node` — so name the command it actually started.
        let fg = mterm_foreground_pid(pgid)
        var buf = [CChar](repeating: 0, count: 256)
        let n = buf.withUnsafeMutableBufferPointer { ptr in
            mterm_proc_name(fg, ptr.baseAddress, Int32(ptr.count))
        }
        let name: String
        if n > 0, let s = String(validatingUTF8: buf), !s.isEmpty {
            name = s
        } else {
            // Lookup failed but the pgid is real — still report the process.
            name = "a process"
        }
        cachedForeground = (pgid, fg, name, now)
        return (fg, name)
    }
}
