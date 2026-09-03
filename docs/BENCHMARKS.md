# Benchmarks

What mTerm has actually been measured doing, as opposed to the targets in
[SPEC.md](../SPEC.md). Where a target has no number here, it has not been
measured and this document says so rather than repeating the target as though
it were a result.

Everything below comes from `scripts/bench.sh`, which is in the repository and
takes about a minute:

```bash
./scripts/bench.sh
```

It compiles the real `Parser`, `TerminalState`, `Trigger` and
`TriggerEvaluator` sources into a plain command-line binary with the release
optimisation settings — no window, no Metal, no PTY — and drives them the way
`Session.drain` does: 8 KB chunks (the PTY read size) into `parser.feed`, and a
`snapshot()` every 8 ms of simulated frame time (its publish interval).

**What that does and doesn't cover.** It measures the CPU half of the pipeline:
bytes in, parsed, applied to the grid, snapshotted for the renderer. It stops
where the GPU begins. Nothing here says anything about glyph rasterisation,
atlas uploads or draw time, and the harness cannot: a headless process has no
drawable and no vsync, so any render timing it produced would be a number about
the harness rather than about mTerm.

## Run of 2026-09-02

Apple M3 Max, macOS 26.6.2 (25G83), release optimisation, 200×50 grid,
32 MB per corpus, median of 5 runs.

### Parse throughput

| Corpus | Parse only | + snapshots | Snapshots taken |
|---|---|---|---|
| `plain` | 30 MB/s | 30 MB/s | 132 |
| `sgr` | 33 MB/s | 33 MB/s | 117 |
| `tui` | 57 MB/s | 58 MB/s | 69 |
| `unicode` | 25 MB/s | 25 MB/s | 153 |

Four shapes, because throughput is not one number:

- **`plain`** — `cat` of a log. Long ASCII lines, printable text and newlines,
  nothing else. This is what "cat a 100 MB log" actually looks like, and it is
  the *slowest* of the first three, because a line of plain text scrolls the
  grid and every scrolled line is a row pushed into the scrollback ring.
- **`sgr`** — coloured build and test output: short SGR runs around most words,
  the shape cargo, `ls --color`, ripgrep and every test runner produce.
- **`tui`** — a full-screen app repainting itself: absolute cursor addressing,
  erase-to-end-of-line, a colour change per row, the frame wrapped in the DEC
  2026 synchronized-output pair. Fastest of the four, because a redraw
  overwrites cells in place and never scrolls.
- **`unicode`** — the slow path on purpose: double-width CJK, emoji and
  combining marks. Each costs a width lookup, and each mark re-composes the
  cell already written.

Snapshotting is free at this resolution — the two columns are the same number.
That is not a measurement failure, it is what the code does: at scroll offset 0
`snapshot()` hands the grid over by reference and Swift's copy-on-write does
the rest. Measured directly it is **0.2 µs** per call.

### Per-frame cost at 200×50

| | Measured | Share of a 120 Hz frame |
|---|---|---|
| `snapshot()` | 0.2 µs | 0.002% |
| `TriggerEvaluator.evaluate()` | 850 µs | 10.2% |
| Frame budget @ 120 Hz | 8333 µs | — |

The trigger pass is the largest per-frame CPU cost in the app by three orders
of magnitude, and it runs every frame over the whole viewport — 63 matches on
the test screen, which is a dense one. It fits, with room, but it is the thing
to watch if the viewport or the trigger list grows.

Note that SPEC.md states the trigger budget as "≤ 1 ms per 1 KB of output".
That unit doesn't describe how triggers actually run: they are not evaluated
per byte of output but per frame over the visible grid, so a screen that never
changes costs the same as one being repainted. The number above is the one that
matters.

### Scrollback memory at 200 columns

`Cell` is 16 bytes, and its stride is 16 — no padding.

| Ring size | Cells alone | Measured footprint | Overhead |
|---|---|---|---|
| 10,000 lines | 30.5 MB | 41.8 MB | 1.37× |
| 50,000 lines | 152.6 MB | 207.1 MB | 1.36× |
| 100,000 lines | 305.2 MB | 414.0 MB | 1.36× |

Measured as the process's physical footprint (the number `footprint(1)`
reports), one fresh process per size, after filling the ring with full-width
rows.

The consistent ~1.36× over the raw cell arithmetic is structural: scrollback is
`[[Cell]]`, one Swift array per row, because rows keep whatever width they had
when they were pushed and resize does not reflow history. Every row therefore
carries an array header and whatever the allocator rounds its bucket up to. A
flat buffer would remove that 36%, at the cost of either reflowing history on
every resize or storing a width per row and packing around it.

This is worth knowing before raising the scrollback setting: 100,000 lines is
not "ten times 10,000 lines of text", it is 414 MB of resident memory per tab.

## Against the targets in SPEC.md

| Target | Measured | |
|---|---|---|
| Scrollback ≤ 200 MB for 10k lines × 200 cols | 41.8 MB | **met**, 4.8× headroom |
| `cat large.log` ≥ 1 GB/s parse+render on M2+ | 30 MB/s parse alone on M3 Max | **missed by ~34×** |
| Idle CPU < 0.1% with one open tab | not cleanly measured — see below | |
| Cold launch to first prompt ≤ 300 ms | not measured | |
| Keystroke → glyph ≤ 1 frame (8.3 ms @ 120 Hz) | not measured | |

The throughput target is the one to take seriously. 30 MB/s means a 100 MB log
takes about 3.3 seconds of parsing, and the 1 GB/s in SPEC.md was written as an
aspiration against Alacritty and Ghostty rather than derived from anything this
code does. It is a real gap, not a rounding error, and closing it is a
performance project rather than a tweak — see the profile below.

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

Sampling the `plain` replay (`sample` on the harness, release build) puts the
remaining time in three places:

1. **Dynamic exclusivity enforcement — the largest single bucket.**
   `swift_beginAccess` / `AccessSet::insert` / `SwiftTLSContext::get` together
   outweigh any one function in `TerminalState`. Every subscript into `cells`
   from a method on the class is a checked access the optimiser cannot prove
   away. The paths that already go through `withUnsafeMutableBufferPointer`
   (`blankCells`, `moveCells`) don't pay it; the ones that touch `cells[i]`
   directly do.
2. **`clearOrphan(at:)`**, called for every printed glyph.
3. **`displayWidth`** — the ASCII fast path returns before touching any Unicode
   property, but the function still sets up a frame large enough for
   `Unicode.Scalar.Properties` (`___chkstk_darwin` and the
   `Unicode.GeneralCategory` metadata accessor both show up on ASCII input).
   Splitting the ASCII test into an always-inlined wrapper over an outlined
   slow path would remove it.

### Already fixed

`Parser.sink` was `weak`. The parser reaches its sink for every printable byte,
and a weak reference cannot be held in a register across that loop: each access
was a `swift_unknownObjectWeakLoadStrong` — a side-table lock and an atomic
retain — with the matching release after it. On a 64 MB ASCII replay those two
calls were **half of all samples on the parsing thread**.

Making it a strong reference took the same replay from 15.6 MB/s to 30.8 MB/s —
every throughput number in this document is post-fix, and the pre-fix figures
were roughly half of them. It cannot cycle: `TerminalState` holds no reference
back to `Parser`, and `Session` owns both.
