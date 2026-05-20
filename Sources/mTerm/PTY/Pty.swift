import Darwin
import Foundation
import CMTermBridge

final class Pty {
    let masterFd: Int32
    let pid: pid_t

    private init(masterFd: Int32, pid: pid_t) {
        self.masterFd = masterFd
        self.pid = pid
    }

    deinit {
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
        bytes.withUnsafeBufferPointer { ptr in
            var remaining = ptr.count
            var offset = 0
            while remaining > 0 {
                let n = Darwin.write(masterFd, ptr.baseAddress! + offset, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += n
                remaining -= n
            }
        }
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
