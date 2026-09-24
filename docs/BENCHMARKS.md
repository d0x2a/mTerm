# Benchmarks

What mTerm has actually been measured doing, as opposed to the targets in
[SPEC.md](../SPEC.md). Where a target has no number here, it has not been
measured and this document says so rather than repeating the target as though
it were a result.

Everything below comes from two scripts in the repository, each of which takes
under a minute:

```bash
./scripts/bench.sh
./scripts/ptybench.sh
```

`bench.sh` compiles the real `Parser`, `TerminalState`, `Trigger` and
`TriggerEvaluator` sources into a plain command-line binary with the release
optimisation settings — no window, no Metal, no PTY — and drives them the way
`Session.drain` does: 8 KB chunks (its read buffer) into `parser.feed`, and a
`snapshot()` every 8 ms of simulated frame time (its publish interval).

`ptybench.sh` puts the kernel back in front of the same code. It `cat`s a
100 MB log through a real pseudo-terminal twice: once into a read loop that
drops every byte, which is the fastest any terminal could take it, and once
into `Parser` and `TerminalState`, read the way `Session` reads — a
non-blocking master drained from a dispatch source, a snapshot published as it
goes. Give it a path to cat your own file instead.

**What that does and doesn't cover.** Both measure the CPU half of the pipeline:
bytes in, parsed, applied to the grid, snapshotted for the renderer. It stops
where the GPU begins. Nothing here says anything about glyph rasterisation,
atlas uploads or draw time, and the harness cannot: a headless process has no
drawable and no vsync, so any render timing it produced would be a number about
the harness rather than about mTerm.

## Run of 2026-09-24

Apple M3 Max, macOS 26.6.2 (25G83), release optimisation, 200×50 grid,
32 MB per corpus, median of 5 runs.

### Parse throughput

| Corpus | Parse only | + snapshots | Snapshots taken |
|---|---|---|---|
| `plain` | 148 MB/s | 151 MB/s | 26 |
| `sgr` | 68 MB/s | 66 MB/s | 60 |
| `tui` | 63 MB/s | 63 MB/s | 63 |
| `unicode` | 28 MB/s | 28 MB/s | 139 |

Four shapes, because throughput is not one number:

- **`plain`** — `cat` of a log. Long ASCII lines, printable text and newlines,
  nothing else. This is what "cat a 100 MB log" actually looks like. It was the
  slowest of the first three until printable text started reaching the grid a
  run at a time (see [Already fixed](#already-fixed)); being almost nothing but
  such runs, it is now the fastest by a distance, and what is left is mostly
  scrolling — every line pushes a row into the scrollback ring.
- **`sgr`** — coloured build and test output: short SGR runs around most words,
  the shape cargo, `ls --color`, ripgrep and every test runner produce. The runs
  are a word long, so half the bytes are still escape sequences.
- **`tui`** — a full-screen app repainting itself: absolute cursor addressing,
  erase-to-end-of-line, a colour change per row, the frame wrapped in the DEC
  2026 synchronized-output pair. A redraw overwrites cells in place and never
  scrolls, but it is escape sequences more than text, so its cost is in CSI
  dispatch and the erases rather than in printing.
- **`unicode`** — the slow path on purpose: double-width CJK, emoji and
  combining marks. Each costs a width lookup, and each mark re-composes the
  cell already written. None of it is ASCII, so it still goes a glyph at a
  time.

Snapshotting is free at this resolution — the two columns are the same number.
That is not a measurement failure, it is what the code does: at scroll offset 0
`snapshot()` hands the grid over by reference and Swift's copy-on-write does
the rest. Measured directly it is **0.2 µs** per call.

### `cat` through a PTY

`scripts/ptybench.sh`: a 100 MB log on a 200×50 PTY, median of 5 runs of each,
the two interleaved.

| Reading end | Time | Throughput | Per read |
|---|---|---|---|
| Nothing — the PTY alone | 0.58 s | 175 MB/s | 1020 B |
| mTerm's parser and grid | 0.77 s | 132 MB/s | 1020 B |

The first row is the ceiling for any terminal on this machine. The kernel
hands the bytes over about 1 KB per read, however large the buffer asking for
them, and no faster than this to a reader that does nothing with them. mTerm
adds 0.19 s to it for this file. Before printable text went in a run at a time
it added 3.35 s: the same file took 3.93 s.

A real PTY also changes how often a frame is published. `Session.drain`
publishes on its way out as well as every 8 ms, and with the parser now
outrunning the kernel it catches up with the writer and leaves thousands of
times per file — 3,000 to 5,000 snapshots here, where the interval alone would
give about a hundred. Each is 0.2 µs, but it also leaves the next write to copy
the grid, since the published snapshot still shares it. Publishing on the
interval alone takes the file from 0.77 s to 0.75 s, so all of that is worth
about 2% — measured by editing the harness, not by a switch in it.

### Per-frame cost at 200×50

| | Measured | Share of a 120 Hz frame |
|---|---|---|
| `snapshot()` | 0.2 µs | 0.002% |
| `TriggerEvaluator.evaluate()` | 800 µs | 9.6% |
| Frame budget @ 120 Hz | 8333 µs | — |

The trigger pass is the largest per-frame CPU cost in the app by three orders
of magnitude, and it runs every frame over the whole viewport — 63 matches on
the test screen, which is a dense one. It fits, with room, but it is the thing
to watch if the viewport or the trigger list grows.

Adding your own trigger rules costs less than the two shipped ones do:

| Enabled rules | Per frame | Share of a 120 Hz frame |
|---|---|---|
| 2 (the builtins alone) | 804 µs | 9.6% |
| 5 | 925 µs | 11.1% |
| 10 | 1136 µs | 13.6% |
| 20 | 1562 µs | 18.7% |

That is about 42 µs per additional rule, measured with word-ish patterns of
the shape people actually write (`\b(?:ERROR|WARN|FATAL)\b`) rather than
anything pathological. The interesting part is the first row: the two builtins
cost more on their own than eighteen ordinary rules added on top of them. The
URL pattern is a long alternation over a curated TLD list and the path pattern
is deliberately loose, so both do real work on every line. Someone can add a
couple of dozen rules of their own before it shows.

Note that SPEC.md states the trigger budget as "≤ 1 ms per 1 KB of output".
That unit doesn't describe how triggers actually run: they are not evaluated
per byte of output but per frame over the visible grid, so a screen that never
changes costs the same as one being repainted. The number above is the one that
matters.

### Scrollback memory at 200 columns

`Cell` is 16 bytes, and its stride is 16 — no padding.

| Ring size | Cells alone | Measured footprint | Overhead |
|---|---|---|---|
| 10,000 lines | 30.5 MB | 41.2 MB | 1.35× |
| 50,000 lines | 152.6 MB | 206.7 MB | 1.35× |
| 100,000 lines | 305.2 MB | 413.6 MB | 1.36× |

Measured as the process's physical footprint (the number `footprint(1)`
reports), one fresh process per size, after filling the ring with full-width
rows.

The consistent ~1.35× over the raw cell arithmetic is structural: scrollback is
`[[Cell]]`, one Swift array per row, because rows keep whatever width they had
when they were pushed and resize does not reflow history. Every row therefore
carries an array header and whatever the allocator rounds its bucket up to. A
flat buffer would remove that 35%, at the cost of either reflowing history on
every resize or storing a width per row and packing around it.

This is worth knowing before raising the scrollback setting: 100,000 lines is
not "ten times 10,000 lines of text", it is 414 MB of resident memory per tab.

## Against the targets in SPEC.md

| Target | Measured | |
|---|---|---|
| Scrollback ≤ 200 MB for 10k lines × 200 cols | 41.2 MB | **met**, 4.9× headroom |
| `cat large.log` ≥ 1 GB/s parse+render on M2+ | 150 MB/s parse alone, 132 MB/s through a PTY, on M3 Max | **missed by ~7×** — and out of reach through a PTY, see below |
| Idle CPU < 0.1% with one open tab | not cleanly measured — see below | |
| Cold launch to first prompt ≤ 300 ms | not measured | |
| Keystroke → glyph ≤ 1 frame (8.3 ms @ 120 Hz) | not measured | |

The throughput target was the one to take seriously, and the 1 GB/s in SPEC.md
was written as an aspiration against Alacritty and Ghostty rather than derived
from anything this code does. It also can't be met through a macOS PTY, by
mTerm or anything else: with nothing at all on the reading end, the PTY
delivers 175 MB/s ([`cat` through a PTY](#cat-through-a-pty)). mTerm takes the
same file at 132 MB/s, 0.77 s against the PTY's 0.58 s, where it took 3.93 s
before printable text went in a run at a time.

So for `cat`, the remaining gap to 1 GB/s belongs to the kernel, not to this
code. The corpora
that are mostly escape sequences — `sgr`, `tui` — are where parsing is still
the limit; see the profile below.

The two unmeasured latency targets need instrumentation inside the app (a
timestamp at launch and at the first prompt; an input event tagged through to
the frame that presents it), not a stopwatch. Until that exists they stay
targets.

Idle CPU wasn't measured cleanly either. The only mTerm running during this
session was hosting the session itself — six tabs, one of them producing output
the whole time — which burned 0.11 s of CPU over a 30 s window (0.37%) at a
271 MB footprint, 515 MB peak. That is a useful sanity check that nothing is
spinning, and it is consistent with the per-tab scrollback cost in the table
above, but it is not the one-tab idle figure the target asks for. Getting that
means a build measured against a window nobody is using.

## What the profile says

`plain` has little left to find: its time is mostly rows scrolling into the
ring. Sampling an SGR-heavy replay and a full-screen repaint instead (`sample`
on a release build of the same sources) puts the remaining time in three
places:

1. **Dynamic exclusivity enforcement — 26–27% of samples.**
   `swift_beginAccess` / `AccessSet::insert` / `SwiftTLSContext::get` together
   outweigh any one function in `TerminalState`. Every access to a stored
   property of the class from one of its methods is a checked access the
   optimiser cannot prove away — `cells[i]`, the cursor, the current colours.
   The paths that go through `withUnsafeMutableBufferPointer` (`blankCells`,
   `moveCells`, printable runs) pay it once per call rather than per cell. As
   an experiment, `-enforce-exclusivity=unchecked` on the same sources gives
   `plain` 181, `sgr` 85 and `tui` 102 MB/s, which is the size of what is
   there. Collecting it for real means holding the hot state in a struct,
   whose fields are checked statically, rather than shipping the flag.
2. **Retain/release — about 15%.** Nearly all of it is called from the parser's
   own loop, which hands `params` and `intermediates` to `parserCSI` as arrays
   for every sequence.
3. **Colour packing — 5–8%.** `PackedColor.init` clamping float colours.
   `applySGR` repacks the theme's colours on `SGR 0` although `defaultFg` and
   `defaultBg` already hold them packed, and copies `theme` — two Strings and
   an Array — on every SGR.

### Already fixed

Printable text reached the grid a glyph at a time. Each byte of it was a call
through `ParserSink`, a `displayWidth` lookup, a `clearOrphan(at:)` and a
checked subscript into `cells`. The parser now hands runs of printable ASCII to `parserPrintASCII`, and
`TerminalState` writes each row's share of a run in one buffer access, with
half-glyph cleanup only at the two ends of the span. That took `plain` from
30 MB/s to 150 MB/s and `sgr` from 35 to 67; `tui` and `unicode` barely move,
since neither is made of printable ASCII. `statecheck` holds the two paths to
the same result: a mixed stream fed both ways, at three widths, has to leave
identical grids and scrollback.

`Parser.sink` was `weak`. The parser reaches its sink for every printable byte,
and a weak reference cannot be held in a register across that loop: each access
was a `swift_unknownObjectWeakLoadStrong` — a side-table lock and an atomic
retain — with the matching release after it. On a 64 MB ASCII replay those two
calls were **half of all samples on the parsing thread**.

Making it a strong reference took the same replay from 15.6 MB/s to 30.8 MB/s,
before printable runs existed. It cannot cycle: `TerminalState` holds no reference
back to `Parser`, and `Session` owns both.
