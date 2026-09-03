// mTerm parse/snapshot benchmark harness.
//
// Compiles the real Parser, TerminalState and TriggerEvaluator into a plain
// command-line binary — no window, no Metal, no PTY — and drives them the way
// Session.drain does: 8 KB chunks into `parser.feed`, a `snapshot()` every
// simulated frame. What it measures is therefore the CPU half of the pipeline
// only. Anything downstream of the snapshot is the GPU's, out of this
// harness's reach, and stays a target in docs/BENCHMARKS.md rather than a
// number here.
//
// Run it with scripts/bench.sh, which knows the swiftc line.

import AppKit
import Foundation

// ThemeStore reads NSApp.effectiveAppearance on init, and Cell() falls back to
// ThemeStore.currentTheme — which mirrors a hardcoded dark theme until
// `shared` is first constructed. Both have to exist before any terminal
// object does.
_ = NSApplication.shared
_ = ThemeStore.shared

let benchCols = 200
let benchRows = 50
let chunkSize = 8192          // Session.drain's PTY read size
let frameInterval: UInt64 = 8_000_000   // Session.drain's publish interval, ns

// MARK: - timing

func time(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
}

/// Median of `reps` timed runs after `warmup` untimed ones. Median rather than
/// best-of: the number worth quoting is the one you get repeatedly, and a
/// single lucky run says nothing about code that allocates.
func measure(warmup: Int = 2, reps: Int = 7, _ body: () -> Void) -> Double {
    for _ in 0..<warmup { body() }
    var samples = (0..<reps).map { _ in time(body) }
    samples.sort()
    return samples[samples.count / 2]
}

/// Somewhere for a result to go that the optimiser can't prove is dead. Timing
/// `_ = state.snapshot()` without this measures nothing at all: the call has
/// no side effects the compiler can see, so -O deletes it and the loop reports
/// 0.000 ms.
var blackhole: Int = 0

/// Resident + compressed footprint of this process, the number `footprint(1)`
/// reports. The scrollback measurement wants this rather than
/// `rows × cols × sizeof(Cell)`, because every scrollback row is its own Swift
/// array: each carries a header and whatever the allocator rounds its bucket
/// up to, and that overhead is the whole question.
func physFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
}

func mb(_ bytes: Int64) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }
func pad(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
}
func rpad(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : String(repeating: " ", count: w - s.count) + s
}

// MARK: - scrollback memory (child mode)
//
// Measured one size per process. Doing all three in one run gave nonsense —
// non-monotonic, and the largest below its own theoretical floor — because the
// allocator reuses what the previous iteration freed and the corpora are still
// resident. A fresh process per size is the only baseline that means anything,
// so the parent below re-execs this binary once per size.

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--mem" {
    let lines = Int(CommandLine.arguments[2])!
    let baseline = physFootprint()
    let state = TerminalState(cols: benchCols, rows: benchRows, scrollback: lines)
    let parser = Parser()
    parser.sink = state
    // One full-width line per row, so no row is short enough to understate it.
    let line = Array(String(repeating: "x", count: benchCols - 1).utf8) + [UInt8(0x0A)]
    var filler = [UInt8]()
    filler.reserveCapacity(line.count * (lines + benchRows))
    for _ in 0..<(lines + benchRows) { filler.append(contentsOf: line) }
    filler.withUnsafeBufferPointer { parser.feed(bytes: $0) }
    // Drop the corpus before weighing: it is the harness's cost, not the
    // buffer's, and at 100k lines it is bigger than what we're measuring.
    filler = []
    let used = Int64(physFootprint()) - Int64(baseline)
    blackhole += state.snapshot().cells.count
    print("\(used)")
    exit(0)
}

// MARK: - corpora
//
// Four shapes, because throughput is not one number: a parser that flies
// through ASCII can crawl through SGR runs, and a TUI's redraw exercises the
// cursor-addressing paths instead of the printing one.

let corpusBytes = 32 << 20

func repeated(_ lines: [String]) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(corpusBytes)
    var i = 0
    while out.count < corpusBytes {
        out.append(contentsOf: Array(lines[i % lines.count].utf8))
        out.append(0x0A)
        i += 1
    }
    return out
}

/// `cat` of a plain log: long ASCII lines, nothing but printable text and
/// newlines. The best case, and what "cat a 100 MB log" actually looks like.
let plain = repeated([
    "2026-09-02T14:22:31.882Z  INFO  request completed status=200 dur=14ms path=/api/v1/sessions",
    "2026-09-02T14:22:31.903Z  WARN  cache miss for key=user:8821 falling back to primary",
    "2026-09-02T14:22:32.011Z DEBUG  pool acquire waited=0.4ms idle=7 active=3 max=16",
    "    at Object.<anonymous> (/Users/dev/src/app/lib/handler.js:118:24)",
])

/// Coloured build/test output: short SGR runs around most words, the shape
/// cargo, ls --color, rg and every test runner produce.
let sgr = repeated([
    "\u{1b}[32m   Compiling\u{1b}[0m \u{1b}[1mserde_json\u{1b}[0m v1.0.127",
    "\u{1b}[31merror[E0308]\u{1b}[0m: \u{1b}[1mmismatched types\u{1b}[0m",
    "  \u{1b}[34m-->\u{1b}[0m src/main.rs:42:17",
    "\u{1b}[38;2;120;200;255mtest\u{1b}[0m parser::wraps_at_edge ... \u{1b}[32mok\u{1b}[0m",
    "\u{1b}[38;5;244m2026-09-02\u{1b}[0m \u{1b}[38;5;208mWARN \u{1b}[0m retrying in \u{1b}[1m250ms\u{1b}[0m",
])

/// A full-screen TUI repainting itself: absolute cursor addressing, erase to
/// end of line, a colour change per row, the whole frame wrapped in the DEC
/// 2026 synchronized-output pair a well-behaved app sends.
let tui: [UInt8] = {
    var out = [UInt8]()
    out.reserveCapacity(corpusBytes)
    var frame = 0
    while out.count < corpusBytes {
        var s = "\u{1b}[?2026h"
        for r in 1...benchRows {
            s += "\u{1b}[\(r);1H\u{1b}[38;5;\((r + frame) % 256)m"
            let label = " \(r) │ mTerm bench frame \(frame) "
            s += label + String(repeating: "·", count: max(0, benchCols - label.count - 1))
            s += "\u{1b}[0m\u{1b}[K"
        }
        s += "\u{1b}[?2026l"
        out.append(contentsOf: Array(s.utf8))
        frame += 1
    }
    return out
}()

/// The slow path on purpose: double-width CJK, emoji and combining marks, each
/// costing a width lookup, and the marks a re-composition of the cell already
/// written.
let unicode = repeated([
    "日本語のテキストが正しく二列を占めること、これが確認したい動作です。",
    "그리고 한국어도 마찬가지로 두 칸을 차지합니다 — 커서 산술이 어긋나면 안 됩니다.",
    "emoji: 🎉 🚀 ✅ 🐛 👩‍💻 🇯🇵 — combining: éòüñ åçêîõ ẘẙ",
    "mixed 中文 and latin, 混排 text with ASCII interleaved 每 隔 一 词",
])

// MARK: - the parse loop
//
// Deliberately Session.drain's shape rather than one big `feed` call: the real
// loop pays for a snapshot every 8 ms, and that copies the whole grid.

struct ParseResult {
    var seconds: Double
    var bytes: Int
    var snapshots: Int
    var throughput: Double { Double(bytes) / seconds / 1_048_576 }
}

func runParse(_ data: [UInt8], withSnapshots: Bool) -> ParseResult {
    var snapshots = 0
    let seconds = measure(warmup: 1, reps: 5) {
        let state = TerminalState(cols: benchCols, rows: benchRows, scrollback: 10_000)
        let parser = Parser()
        parser.sink = state
        snapshots = 0
        var lastPublish = DispatchTime.now().uptimeNanoseconds
        data.withUnsafeBufferPointer { buf in
            var off = 0
            while off < buf.count {
                let n = min(chunkSize, buf.count - off)
                parser.feed(bytes: UnsafeBufferPointer(start: buf.baseAddress! + off, count: n))
                off += n
                guard withSnapshots else { continue }
                let now = DispatchTime.now().uptimeNanoseconds
                if now &- lastPublish >= frameInterval {
                    lastPublish = now
                    blackhole &+= state.snapshot().cells.count
                    snapshots += 1
                }
            }
        }
    }
    return ParseResult(seconds: seconds, bytes: data.count, snapshots: snapshots)
}

// MARK: - report

func header(_ s: String) {
    print("\n\(s)")
    print(String(repeating: "─", count: s.count))
}

let machine: String = {
    var size = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    var buf = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
    return String(cString: buf)
}()

print("mTerm bench — \(machine), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("grid \(benchCols)×\(benchRows), \(chunkSize)-byte chunks, \(corpusBytes >> 20) MB per corpus")

header("Parse throughput (parser + TerminalState; no GPU, no PTY)")
print(pad("corpus", 10) + rpad("parse only", 14) + rpad("+ snapshots", 14) + rpad("snaps", 8))
for (name, data) in [("plain", plain), ("sgr", sgr), ("tui", tui), ("unicode", unicode)] {
    let bare = runParse(data, withSnapshots: false)
    let full = runParse(data, withSnapshots: true)
    print(pad(name, 10)
          + rpad(String(format: "%.0f MB/s", bare.throughput), 14)
          + rpad(String(format: "%.0f MB/s", full.throughput), 14)
          + rpad("\(full.snapshots)", 8))
}

header("Per-frame cost at \(benchCols)×\(benchRows)")
do {
    let state = TerminalState(cols: benchCols, rows: benchRows)
    let parser = Parser()
    parser.sink = state
    // A screen with something on it: snapshot copies cells whatever they
    // hold, but the trigger pass only works where there is text to match.
    let screen = Array("""
    $ swift build -c release 2>&1 | tee /Users/dev/src/mTerm/build.log
    warning: /Users/dev/src/mTerm/Sources/mTerm/Terminal/TerminalState.swift:118:9: unused
    see https://github.com/d0x2a/mTerm/issues/42 and docs/BENCHMARKS.md for context
    fetching https://code.d0x2a.com/pkg/index.json (localhost:3000/health mirrors it)

    """.utf8)
    for _ in 0..<(benchRows / 5) { screen.withUnsafeBufferPointer { parser.feed(bytes: $0) } }

    // Timed in batches: one snapshot is faster than the clock call that
    // would measure it, because at scrollOffset 0 the grid is not copied at
    // all — the arrays are handed over by reference and Swift's COW does the
    // rest. Per-call timing of that reports zero and teaches nothing.
    let snapBatch = 2_000
    let snapSeconds = measure(reps: 9) {
        for _ in 0..<snapBatch { blackhole &+= state.snapshot().cells.count }
    } / Double(snapBatch)
    print("  snapshot()           " + rpad(String(format: "%.1f µs", snapSeconds * 1e6), 10))

    let snap = state.snapshot()
    let evaluator = TriggerEvaluator()
    let matches = evaluator.evaluate(snapshot: snap).count
    let trigSeconds = measure(reps: 51) { blackhole &+= evaluator.evaluate(snapshot: snap).count }
    print("  triggers.evaluate()  " + rpad(String(format: "%.1f µs", trigSeconds * 1e6), 10)
          + "   (\(matches) matches on screen)")
    print("  budget @ 120 Hz      " + rpad("8333.0 µs", 10))
}

header("Scrollback memory at \(benchCols) cols")
print("  sizeof(Cell) \(MemoryLayout<Cell>.size) bytes, stride \(MemoryLayout<Cell>.stride)")
for lines in [10_000, 50_000, 100_000] {
    // Fresh process per size — see the --mem branch above.
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["--mem", "\(lines)"]
    let pipe = Pipe()
    child.standardOutput = pipe
    try! child.run()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    child.waitUntilExit()
    let used = Int64(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    let cellsOnly = Int64(lines * benchCols * MemoryLayout<Cell>.stride)
    let overhead = Double(used) / Double(cellsOnly)
    print("  " + rpad("\(lines)", 7) + " lines  "
          + rpad(mb(used), 10) + " measured"
          + "   (" + mb(cellsOnly) + " of cells, "
          + String(format: "%.2f×", overhead) + " with row overhead)")
}

if blackhole == Int.min { print("unreachable") }   // keeps the sink alive
print("")
