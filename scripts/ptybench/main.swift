// mTerm PTY benchmark harness.
//
// Times `cat` of a large file through a real pseudo-terminal, two ways. Once
// with nothing on the reading end but a read loop, which is as fast as the
// kernel will hand the bytes over at all — the ceiling for any terminal on
// this Mac. And once into the real Parser and TerminalState, read the way
// Session does: a non-blocking master drained from a dispatch read source
// until the writer pauses, a snapshot published every 8 ms. The gap between
// the two is what mTerm costs.
//
// scripts/bench.sh measures the same parser from memory, which says how fast
// it is; this says whether that matters once the kernel is in front of it.
// Nothing downstream of the snapshot is here: no window, no Metal.
//
// Run it with scripts/ptybench.sh, which knows the swiftc line. With no
// argument it cats a generated 100 MB log; give it a path to cat your own.

import AppKit
import Foundation

// ThemeStore reads NSApp.effectiveAppearance on init, and Cell() falls back to
// ThemeStore.currentTheme — which mirrors a hardcoded dark theme until
// `shared` is first constructed. Both have to exist before any terminal
// object does.
_ = NSApplication.shared
_ = ThemeStore.shared

let ptyCols: UInt16 = 200
let ptyRows: UInt16 = 50
let readSize = 8192                     // Session.drain's read buffer
let publishInterval: UInt64 = 8_000_000 // Session.drain's, ns
let reps = 5

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

// MARK: - corpus

/// The same lines as bench.sh's `plain` corpus: `cat` of a log, printable text
/// and newlines, nothing else.
let logLines = [
    "2026-09-02T14:22:31.882Z  INFO  request completed status=200 dur=14ms path=/api/v1/sessions",
    "2026-09-02T14:22:31.903Z  WARN  cache miss for key=user:8821 falling back to primary",
    "2026-09-02T14:22:32.011Z DEBUG  pool acquire waited=0.4ms idle=7 active=3 max=16",
    "    at Object.<anonymous> (/Users/dev/src/app/lib/handler.js:118:24)",
]

let path: String = {
    if CommandLine.arguments.count > 1 { return CommandLine.arguments[1] }
    let generated = (NSTemporaryDirectory() as NSString).appendingPathComponent("mterm-ptybench.log")
    let size = 100 * 1_048_576
    // Kept between runs; it is the same bytes every time.
    let existing = (try? FileManager.default.attributesOfItem(atPath: generated))?[.size] as? Int
    if existing != size {
        var out = [UInt8]()
        out.reserveCapacity(size + 128)
        var i = 0
        while out.count < size {
            out.append(contentsOf: Array(logLines[i % logLines.count].utf8))
            out.append(0x0A)
            i += 1
        }
        FileManager.default.createFile(atPath: generated, contents: Data(out[..<size]))
    }
    return generated
}()

// MARK: - the two readers

struct Run {
    var seconds: Double
    var bytes: Int
    var reads: Int
    var snapshots: Int
}

/// `cat path` on a fresh PTY the bench's size. The master comes back blocking.
func spawnCat() -> (fd: Int32, pid: pid_t) {
    // Built before the fork, so the child does nothing but exec.
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/cat"), strdup(path), nil]
    var size = winsize(ws_row: ptyRows, ws_col: ptyCols, ws_xpixel: 0, ws_ypixel: 0)
    var fd: Int32 = -1
    let pid = forkpty(&fd, nil, nil, &size)
    if pid == 0 {
        execv("/bin/cat", argv)
        _exit(127)
    }
    argv.forEach { free($0) }
    precondition(pid > 0, "forkpty failed: errno \(errno)")
    return (fd, pid)
}

/// Nothing on the reading end: every byte read and dropped.
func ptyAlone() -> Run {
    let start = now()
    let (fd, pid) = spawnCat()
    var buf = [UInt8](repeating: 0, count: readSize)
    var bytes = 0, reads = 0
    while true {
        let n = buf.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, $0.count) }
        if n > 0 {
            bytes += n
            reads += 1
        } else if n < 0 && errno == EINTR {
            continue
        } else {
            break               // 0, or EIO once the child has gone
        }
    }
    let seconds = Double(now() - start) / 1e9
    close(fd)
    waitpid(pid, nil, 0)
    return Run(seconds: seconds, bytes: bytes, reads: reads, snapshots: 0)
}

/// Session's read loop, with the parts that aren't reading taken out.
func throughMTerm() -> Run {
    let start = now()
    let (fd, pid) = spawnCat()
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

    let state = TerminalState(cols: Int(ptyCols), rows: Int(ptyRows), scrollback: 10_000)
    let parser = Parser()
    parser.sink = state
    let queue = DispatchQueue(label: "mterm.ptybench", qos: .userInteractive)
    let finished = DispatchSemaphore(value: 0)
    let publishedLock = NSLock()
    var published: TerminalSnapshot?
    var buf = [UInt8](repeating: 0, count: readSize)
    var bytes = 0, reads = 0, snapshots = 0
    var lastPublish = start

    func publish() {
        let snapshot = state.viewportSnapshot(scrollOffset: 0)
        publishedLock.lock()
        published = snapshot
        publishedLock.unlock()
        snapshots += 1
    }

    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler {
        // Session.drain: read until the writer pauses, publishing as it goes
        // and once more on the way out.
        var produced = false
        while true {
            let n = buf.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                buf.withUnsafeBufferPointer {
                    parser.feed(bytes: UnsafeBufferPointer(start: $0.baseAddress, count: n))
                }
                bytes += n
                reads += 1
                produced = true
                let t = now()
                if t &- lastPublish >= publishInterval {
                    lastPublish = t
                    publish()
                }
            } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                if produced { publish() }
                return
            } else {
                if produced { publish() }
                source.cancel()
                finished.signal()
                return
            }
        }
    }
    source.resume()
    finished.wait()
    let seconds = Double(now() - start) / 1e9
    close(fd)
    waitpid(pid, nil, 0)
    precondition(published != nil)
    return Run(seconds: seconds, bytes: bytes, reads: reads, snapshots: snapshots)
}

// MARK: - report

let machine: String = {
    var size = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    var buf = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
    return String(cString: buf)
}()

func pad(_ s: String, _ w: Int) -> String { s.padding(toLength: w, withPad: " ", startingAt: 0) }
func rpad(_ s: String, _ w: Int) -> String { String(repeating: " ", count: max(0, w - s.count)) + s }
func mb(_ bytes: Int) -> Double { Double(bytes) / 1_048_576 }

let fileSize = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
print("mTerm ptybench — \(machine), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("cat of \(path) (\(String(format: "%.1f", mb(fileSize))) MB)")
print("\(ptyCols)×\(ptyRows) PTY, \(readSize)-byte reads, \(reps) runs of each, interleaved")

// Interleaved, so a machine that is busier for one stretch of the run is
// busier for both.
var alone: [Run] = []
var mterm: [Run] = []
for _ in 0..<reps {
    alone.append(ptyAlone())
    mterm.append(throughMTerm())
}

func median(_ runs: [Run]) -> Run { runs.sorted { $0.seconds < $1.seconds }[runs.count / 2] }

print("")
print(pad("", 12) + rpad("median", 10) + rpad("range", 16) + rpad("throughput", 14)
      + rpad("per read", 12) + rpad("snapshots", 11))
for (name, runs) in [("PTY alone", alone), ("mTerm", mterm)] {
    let m = median(runs)
    let lo = runs.map(\.seconds).min()!, hi = runs.map(\.seconds).max()!
    print(pad(name, 12)
          + rpad(String(format: "%.2f s", m.seconds), 10)
          + rpad(String(format: "%.2f–%.2f s", lo, hi), 16)
          + rpad(String(format: "%.0f MB/s", mb(m.bytes) / m.seconds), 14)
          + rpad("\(m.bytes / max(m.reads, 1)) B", 12)
          + rpad(name == "mTerm" ? "\(m.snapshots)" : "—", 11))
}

// More bytes arrive than the file holds: the line discipline's ONLCR turns
// every newline into CR LF on the way through, as it does for any terminal.
let extra = median(alone).bytes - fileSize
if extra > 0 {
    print("\n\(extra) bytes more than the file: the PTY sends each newline as CR LF.")
}
let cost = median(mterm).seconds - median(alone).seconds
print(String(format: "mTerm adds %.2f s over the PTY alone on this file (%.0f%%).",
             cost, 100 * cost / median(alone).seconds))
