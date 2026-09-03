import Foundation
import simd

struct CellAttrs: OptionSet {
    let rawValue: UInt8
    static let bold      = CellAttrs(rawValue: 1 << 0)
    static let italic    = CellAttrs(rawValue: 1 << 1)
    static let underline = CellAttrs(rawValue: 1 << 2)
    static let inverse   = CellAttrs(rawValue: 1 << 3)
    static let faint     = CellAttrs(rawValue: 1 << 4)
}

struct Cell {
    var scalar: Unicode.Scalar
    var fg: PackedColor
    var bg: PackedColor
    var attrs: CellAttrs
    /// Columns this cell occupies: 1 for an ordinary glyph, 2 for the leading
    /// half of a double-width one, and 0 for the trailing half it reserves.
    /// Kept a plain byte so Cell stays trivially copyable — the grid is copied
    /// wholesale on every snapshot.
    var width: UInt8
    /// OSC 8 hyperlink id, resolved through TerminalSnapshot.links; 0 means
    /// the cell isn't part of a link. Lands in the two bytes that were already
    /// padding after `width`, so Cell is still 16 bytes and the snapshot copy
    /// costs exactly what it did.
    var link: UInt16

    init(scalar: Unicode.Scalar = " ",
         fg: PackedColor? = nil,
         bg: PackedColor? = nil,
         attrs: CellAttrs = [],
         width: UInt8 = 1,
         link: UInt16 = 0) {
        self.scalar = scalar
        // Only reach for the theme when a color is actually missing. That read
        // takes a lock and copies a Theme — two Strings and an Array, so atomic
        // refcount traffic on top — while putGlyph, the per-character hot path,
        // always supplies both colors and threw the result away.
        if let fg, let bg {
            self.fg = fg
            self.bg = bg
        } else {
            let theme = ThemeStore.currentTheme
            self.fg = fg ?? PackedColor(theme.foreground)
            self.bg = bg ?? PackedColor(theme.background)
        }
        self.attrs = attrs
        self.width = width
        self.link = link
    }

    var isBlank: Bool { scalar == " " && attrs.isEmpty }

    /// The reserved trailing half of a double-width glyph. It carries no text
    /// of its own, so copy and search skip it.
    var isContinuation: Bool { width == 0 }
}

struct TerminalSnapshot {
    let cols: Int
    let rows: Int
    let cells: [Cell]
    /// The active grid is a ring of rows — scrolling rotates an offset rather
    /// than moving every cell — so a viewport row is not necessarily the same
    /// row of `cells`. Always 0 for a scrolled-back viewport, which is composed
    /// in logical order. Use `rowStart(_:)` rather than reading this directly.
    let rowOffset: Int
    /// Per viewport row: did this row run out of width and continue onto the
    /// next one? Always in viewport order, unlike `cells`, which is a ring.
    /// Lets a consumer rebuild the logical line a wrapped row belongs to —
    /// a URL split across two rows is one URL, not two fragments.
    let rowWrapped: [Bool]
    let cursorCol: Int
    let cursorRow: Int
    let cursorVisible: Bool
    let scrollbackLines: Int       // total lines available in scrollback
    let scrollOffset: Int          // how many of those are showing above the grid
    let title: String              // last OSC 0/2 title from the shell
    let prompts: [PromptMark]      // prompt markers currently visible in the viewport
    let scrolledRows: Int          // total lines ever pushed to scrollback (for absolute coords)
    let currentDirectory: String?  // last OSC 7 reported cwd
    let usingAlt: Bool             // alt buffer is showing (vim, less, ...)
    /// OSC 8 hyperlink targets, indexed by `Cell.link` - 1. Empty until
    /// something on screen actually emits one.
    let links: [String]

    /// Index in `cells` where viewport row `row` begins.
    @inline(__always)
    func rowStart(_ row: Int) -> Int {
        if rowOffset == 0 { return row * cols }
        let physical = row + rowOffset
        return (physical >= rows ? physical - rows : physical) * cols
    }
}

/// A regex/substring match somewhere in scrollback or the active grid. Both
/// column endpoints are zero-based; endCol is exclusive.
struct SearchMatch: Equatable {
    let absoluteLine: Int
    let startCol: Int
    let endCol: Int
}

/// A semantic prompt marker (from OSC 133) that's visible in the current
/// viewport. exitCode is nil until OSC 133;D fires for that prompt.
struct PromptMark {
    let viewportRow: Int
    let exitCode: Int?
}

/// A normalized rectangular-by-line text selection in viewport coords.
/// Both endpoints are inclusive.
/// A selected span in *viewport* rows, for drawing. The view stores selections
/// in absolute lines and converts to this at render time — see
/// TerminalView.viewportSelection(snapshot:).
struct Selection {
    let startCol: Int
    let startRow: Int
    let endCol: Int
    let endRow: Int

    func contains(col: Int, row: Int) -> Bool {
        if row < startRow || row > endRow { return false }
        if startRow == endRow { return col >= startCol && col <= endCol }
        if row == startRow { return col >= startCol }
        if row == endRow { return col <= endCol }
        return true
    }
}

/// What the child asked us to report. Each mode is a superset of the one above
/// it, so the view can compare with `>=`-style checks on the case list.
enum MouseTracking {
    case off
    case x10            // ?9    — press only
    case normal         // ?1000 — press and release
    case buttonEvent    // ?1002 — plus drags while a button is down
    case anyEvent       // ?1003 — plus bare motion
}

/// How a mouse report is framed on the wire.
enum MouseEncoding {
    case x10            // legacy: bytes offset by 32, so columns stop at 223
    case sgr            // ?1006: CSI < b ; x ; y M|m — no column limit
}

final class TerminalState: ParserSink {
    /// Palette this buffer paints its default-coloured cells in, and answers
    /// OSC 10/11/4 colour queries from.
    ///
    /// Per buffer rather than read from `ThemeStore` at each call site,
    /// because a profile can pin a theme of its own: two tabs in one window
    /// may be painting in different palettes at the same time. Kept in step
    /// with the tab's effective theme by `applyThemeChange`, which also
    /// remaps every cell already on screen.
    /// Whether a resize reflows this buffer's lines.
    ///
    /// False for a tmux pane. tmux owns the pane: `refresh-client -C` resizes
    /// it, the program in it sees SIGWINCH and repaints, and the repaint
    /// arrives as `%output` a moment later. Reflowing our copy in the meantime
    /// re-wraps lines a full-screen program never meant to be re-wrapped —
    /// mid-word, mid-frame, for every step of a window drag — and then throws
    /// the result away when the repaint lands. Same reasoning the alt screen
    /// is not reflowed on.
    let reflowsOnResize: Bool

    private(set) var theme: Theme
    /// `theme`'s fg/bg, packed once. A blank cell is made often enough — every
    /// erase, every scrolled-in row — that repacking two colours each time
    /// would land in the parse hot path.
    private var defaultFg: PackedColor
    private var defaultBg: PackedColor
    /// A blank in this buffer's palette. Replaces a bare `Cell()`, which
    /// reaches for the *app's* theme and would paint a profile-themed tab's
    /// blanks in the wrong colours.
    private var blankCell: Cell { Cell(fg: defaultFg, bg: defaultBg) }

    private(set) var cols: Int
    private(set) var rows: Int
    private var cells: [Cell]
    /// Physical row of logical row 0. Scrolling the whole grid rotates this
    /// instead of moving every cell, which is what makes a line of output
    /// O(cols) rather than O(rows × cols). Kept in [0, rows).
    private var rowOffset = 0

    /// Per-row: did this line run off the right edge and continue on the row
    /// below? Set only by autowrap, so an explicit newline leaves it false.
    /// Indexed by ring slot, exactly like `cells`, so rotating `rowOffset`
    /// carries the flags along with the rows they describe.
    private var rowWrapped: [Bool] = []

    // Scrollback only retains rows evicted from the PRIMARY screen. Alt-screen
    // scrolls (vim, etc.) are discarded — that matches xterm/iTerm behavior.
    /// Scrollback as a ring. Storage grows to `maxScrollback` rows and then
    /// stops: the oldest row's buffer is recycled to carry the newest, so a
    /// scrolled line costs no allocation in the steady state, and evicting is
    /// an index bump rather than shifting every surviving row down by one.
    /// Rows keep whatever width they had when they were pushed — resize does
    /// not reflow history — so this can't be one flat buffer.
    private var scrollbackStore: [[Cell]] = []
    /// Wrapped flags for `scrollbackStore`, same ring slots. A line that wrapped
    /// keeps its continuation marked after it scrolls off, so reflow can rejoin
    /// it with the rows that followed.
    private var scrollbackWrapped: [Bool] = []
    private var scrollbackStart = 0      // ring slot holding the oldest row
    private var scrollbackCount = 0
    private let maxScrollback: Int

    // Absolute line numbering — every row ever pushed into scrollback bumps this
    // counter. Together with cursorRow it gives a unique, stable identifier for
    // any row that has ever existed in the primary screen. Used by OSC 133
    // prompt markers so jump-to-prompt and gutter dots survive scrolling.
    private(set) var scrolledRows: Int = 0

    private struct Prompt {
        let absoluteLine: Int
        var exitCode: Int?
    }
    private var prompts: [Prompt] = []
    var promptAbsoluteLines: [Int] { prompts.map { $0.absoluteLine } }

    // Modes the child toggles that change how text lands on the grid.
    private var autoWrap: Bool = true               // DECAWM (?7)
    private var originMode: Bool = false            // DECOM (?6)

    // Modes the *view* has to honor. Read through Session on the main thread.
    private(set) var bracketedPaste: Bool = false   // ?2004
    private(set) var reportFocus: Bool = false      // ?1004
    private(set) var mouseTracking: MouseTracking = .off
    private(set) var mouseEncoding: MouseEncoding = .x10
    /// ?1007 — while the alt screen is up, the wheel is sent as cursor keys.
    /// On by default, like every terminal a full-screen app expects to be
    /// running under: the alt screen keeps no scrollback of its own, so a
    /// program that doesn't track the mouse (less, man, codex) has no other
    /// way to hear about the wheel.
    private(set) var alternateScroll: Bool = true   // ?1007

    // Tab stops as a set of columns; every 8 by default, but HTS/TBC let the
    // child place its own.
    private var tabStops: Set<Int> = []

    // G0/G1 charset designations (the byte from `ESC ( c` / `ESC ) c`) and
    // which one SI/SO has shifted in.
    private var charsets: [UInt8] = [0x42, 0x42]    // 'B' — ASCII
    private var activeCharset: Int = 0

    /// Last glyph actually placed, for REP.
    private var lastPrinted: Unicode.Scalar? = nil

    /// Writes bytes back to the child — device attribute and cursor position
    /// answers. Session points this at the PTY.
    var onReply: (([UInt8]) -> Void)?

    // DECSTBM scrolling margins, 0-based and inclusive. Defaults to the whole
    // screen; only rows between them scroll on a line feed.
    private var scrollTop: Int = 0
    private var scrollBottom: Int

    // DEC 2026 synchronized output. While a frame is open the view keeps
    // presenting the previous one so a multi-line redraw lands at once. The
    // deadline is the safety valve: a child that sets the mode and then dies —
    // or takes pathologically long between frames — must not freeze the view.
    private var syncUpdateDeadline: CFAbsoluteTime?
    private static let syncUpdateTimeout: CFAbsoluteTime = 0.25

    private(set) var cursorCol: Int = 0
    private(set) var cursorRow: Int = 0
    private(set) var cursorVisible: Bool = true
    private(set) var title: String = ""
    private(set) var currentDirectory: String? = nil

    /// A full-screen erase is the first half of a repaint, and an app that
    /// wraps the repaint in a synchronized update doesn't always wrap the
    /// erase: codex flushes `2J`/`3J` on its own, outside the bracket, and
    /// only opens ?2026 for the re-emission that follows. Between the two the
    /// grid is empty and the gate is open, and any of the three present paths
    /// that ran in that window put a blank screen up for a frame — on every
    /// resize. So an erase opens a short hold of its own. The app's ?2026h
    /// replaces it with the real deadline, its ?2026l ends it, and if nothing
    /// follows — `clear` at an idle prompt — the timeout lets the blank
    /// screen through after a delay no one can see.
    private static let eraseHoldTimeout: CFAbsoluteTime = 0.08

    private func holdForRepaintAfterErase() {
        // Against the live flag rather than `syncUpdateDeadline != nil`: a
        // deadline that has already passed is not an open update, and leaving
        // it in place would wedge every later erase behind a hold that can no
        // longer be re-armed.
        guard !synchronizedUpdateActive else { return }
        syncUpdateDeadline = CFAbsoluteTimeGetCurrent() + Self.eraseHoldTimeout
    }

    /// When the current hold runs out, or nil when no update is open.
    ///
    /// This is what gets published alongside the grid, rather than a sampled
    /// Bool. The flag is only ever read on the session queue, and that queue
    /// runs when the child writes — so a hold armed by the last bytes of a
    /// burst froze at `true` for as long as the child then stayed quiet. That
    /// is exactly the shape of `clear` at an idle prompt: the erase arms the
    /// hold, the shell writes its new prompt and goes silent, and with no
    /// further output to republish the flag, every tick kept holding the
    /// *pre-erase* frame. The screen kept the old lines, and the cursor
    /// stopped blinking, until the next keystroke produced output. Handing the
    /// view the deadline instead lets it re-check against the clock on a tick
    /// that no new output drives.
    var synchronizedUpdateDeadline: CFAbsoluteTime? { syncUpdateDeadline }

    /// True while the child holds a synchronized update open (DEC 2026), until
    /// the safety deadline passes.
    var synchronizedUpdateActive: Bool {
        guard let deadline = syncUpdateDeadline else { return false }
        if CFAbsoluteTimeGetCurrent() >= deadline {
            syncUpdateDeadline = nil
            return false
        }
        return true
    }

    /// A device control string the child opened, fired on the parser queue in
    /// stream order. `Session` watches these for `tmux -CC`'s `ESC P 1000 p`;
    /// nothing here knows what any particular DCS means.
    var onDCSStart: ((_ params: [Int], _ final: UInt8) -> Void)?
    var onDCSPut: ((ArraySlice<UInt8>) -> Void)?
    var onDCSEnd: (() -> Void)?

    /// Fired on the parser (session) queue when the child writes BEL (0x07).
    /// Session marshals this to the main thread.
    var onBell: (() -> Void)?
    /// Fired on the parser queue for an OSC 9 / OSC 777 desktop-notification
    /// escape. `title` is empty for OSC 9, which carries only a body.
    var onNotify: ((_ title: String, _ body: String) -> Void)?

    private var currentFg: PackedColor
    private var currentBg: PackedColor
    private var currentAttrs: CellAttrs = []

    // DECSC / DECRC slot (separate from alt-screen stash).
    private var savedCursor: (col: Int, row: Int) = (0, 0)
    private var savedFg: PackedColor
    private var savedBg: PackedColor
    private var savedAttrs: CellAttrs = []
    private var savedLink: UInt16 = 0

    // Alt-screen support. When usingAlt is true, `cells` is the alt buffer
    // and `stashed*` holds the primary state.
    private(set) var usingAlt: Bool = false
    private var stashedCells: [Cell] = []
    private var stashedRowWrapped: [Bool] = []
    private var stashedCursor: (col: Int, row: Int) = (0, 0)
    private var stashedFg: PackedColor
    private var stashedBg: PackedColor
    private var stashedAttrs: CellAttrs = []
    private var stashedLink: UInt16 = 0

    // MARK: OSC 8 hyperlinks

    /// Targets behind the ids in `Cell.link`, which is 1-based so 0 can mean
    /// "not a link". Interned by URI, so the same target printed once per file
    /// by `ls --hyperlink` is a single entry. Sharing an id across distant runs
    /// is harmless because marking is per contiguous run, not per id.
    private var linkURIs: [String] = []
    private var linkIDs: [String: UInt16] = [:]
    /// Table size that triggers a sweep, raised past whatever survives one so a
    /// screen legitimately holding thousands of links doesn't sweep per link.
    private var linkSweepAt = 4096
    /// The link glyphs are being written into. Drawing state like SGR, but
    /// deliberately not in CellAttrs: SGR 0 does not close a hyperlink.
    private var currentLink: UInt16 = 0

    /// `scrollback` defaults to the configured depth. It is fixed for the life
    /// of the buffer — the ring is sized here — so a change in Settings reaches
    /// the tabs opened after it rather than reallocating the history of every
    /// live one.
    init(cols: Int, rows: Int,
         scrollback: Int = ThemeStore.shared.settings.scrollbackLines,
         theme: Theme = ThemeStore.currentTheme,
         reflowsOnResize: Bool = true) {
        self.reflowsOnResize = reflowsOnResize
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        self.maxScrollback = max(0, scrollback)
        self.scrollBottom = self.rows - 1
        self.theme = theme
        self.defaultFg = PackedColor(theme.foreground)
        self.defaultBg = PackedColor(theme.background)
        self.currentFg = PackedColor(theme.foreground)
        self.currentBg = PackedColor(theme.background)
        self.savedFg = PackedColor(theme.foreground)
        self.savedBg = PackedColor(theme.background)
        self.stashedFg = PackedColor(theme.foreground)
        self.stashedBg = PackedColor(theme.background)
        self.cells = Array(repeating: Cell(fg: self.defaultFg, bg: self.defaultBg),
                           count: self.cols * self.rows)
        self.rowWrapped = Array(repeating: false, count: self.rows)
        self.tabStops = Self.defaultTabStops(cols: self.cols)
    }

    func resize(cols requestedCols: Int, rows requestedRows: Int) {
        let newCols = max(1, requestedCols)
        let newRows = max(1, requestedRows)
        if newCols == cols && newRows == rows { return }

        // Reflow reads the buffer in logical row order.
        normalizeRowOffset()

        if !reflowsOnResize {
            // A tmux pane, which repaints itself. Clip or pad, and let the
            // repaint fill it in.
            cells = Self.resizedGrid(cells, oldCols: cols, oldRows: rows,
                                     newCols: newCols, newRows: newRows,
                                     blank: blankCell)
            rowWrapped = Array(repeating: false, count: newRows)
            cursorCol = min(cursorCol, newCols - 1)
            cursorRow = min(cursorRow, newRows - 1)
        } else if usingAlt {
            // The alt screen is not reflowed: full-screen apps repaint from
            // scratch when they see SIGWINCH, and xterm discards its alt
            // content the same way. The primary buffer stashed behind it does
            // reflow, so leaving vim lands on a correctly-wrapped shell.
            cells = Self.resizedGrid(cells, oldCols: cols, oldRows: rows,
                                     newCols: newCols, newRows: newRows,
                                     blank: blankCell)
            // The flags have to track `rows` or the next wrap indexes past the
            // end of the array. The alt screen has no continuations worth
            // keeping — the app repaints it — so they all start clear.
            rowWrapped = Array(repeating: false, count: newRows)
            let r = reflowPrimary(grid: stashedCells, wrapped: stashedRowWrapped,
                                  cursorCol: stashedCursor.col,
                                  cursorRow: stashedCursor.row,
                                  newCols: newCols, newRows: newRows)
            stashedCells = r.cells
            stashedRowWrapped = r.wrapped
            stashedCursor = (r.cursorCol, r.cursorRow)
        } else {
            let r = reflowPrimary(grid: cells, wrapped: rowWrapped,
                                  cursorCol: cursorCol, cursorRow: cursorRow,
                                  newCols: newCols, newRows: newRows)
            cells = r.cells
            rowWrapped = r.wrapped
            cursorCol = r.cursorCol
            cursorRow = r.cursorRow
        }

        cols = newCols
        rows = newRows
        rowOffset = 0
        cursorCol = min(cursorCol, cols - 1)
        cursorRow = min(cursorRow, rows - 1)
        stashedCursor.col = min(stashedCursor.col, cols - 1)
        stashedCursor.row = min(stashedCursor.row, rows - 1)
        savedCursor.col = min(savedCursor.col, cols - 1)
        savedCursor.row = min(savedCursor.row, rows - 1)
        // Margins and tab stops don't survive a reflow; xterm drops them on
        // resize too.
        scrollTop = 0
        scrollBottom = rows - 1
        tabStops = Self.defaultTabStops(cols: cols)
    }

    /// Index in `cells` where logical row `row` begins.
    @inline(__always)
    private func rowBase(_ row: Int) -> Int {
        if rowOffset == 0 { return row * cols }
        let physical = row + rowOffset
        return (physical >= rows ? physical - rows : physical) * cols
    }

    /// Ring slot holding logical row `row` — the `rowWrapped` counterpart of
    /// `rowBase`, which gives the same row's offset into `cells`.
    @inline(__always)
    private func ringRow(_ row: Int) -> Int {
        if rowOffset == 0 { return row }
        let physical = row + rowOffset
        return physical >= rows ? physical - rows : physical
    }

    /// Ring slot holding scrollback row `i`, counting from the oldest.
    @inline(__always)
    private func scrollbackSlot(_ i: Int) -> Int {
        let idx = scrollbackStart + i
        return idx < scrollbackStore.count ? idx : idx - scrollbackStore.count
    }

    /// Scrollback row `i`, oldest first.
    @inline(__always)
    private func scrollbackRow(_ i: Int) -> [Cell] {
        scrollbackStore[scrollbackSlot(i)]
    }

    /// Logical row `row` as a standalone array.
    @inline(__always)
    private func gridRow(_ row: Int) -> [Cell] {
        let base = rowBase(row)
        return Array(cells[base ..< base + cols])
    }

    /// Rewrites the ring so logical row 0 sits at physical row 0. Used by the
    /// paths that reinterpret the whole buffer (resize) rather than making each
    /// of them ring-aware.
    private func normalizeRowOffset() {
        guard rowOffset != 0 else { return }
        var rebuilt = [Cell](repeating: blankCell, count: cells.count)
        rebuilt.withUnsafeMutableBufferPointer { dst in
            cells.withUnsafeBufferPointer { src in
                for r in 0..<rows {
                    memcpy(dst.baseAddress! + r * cols,
                           src.baseAddress! + rowBase(r),
                           cols * MemoryLayout<Cell>.stride)
                }
            }
        }
        // The flags are ring-indexed like the rows, so they rotate alongside.
        // Computed before rowOffset is cleared, since ringRow reads it.
        var rebuiltWrapped = [Bool](repeating: false, count: rows)
        for r in 0..<rows { rebuiltWrapped[r] = rowWrapped[ringRow(r)] }
        rowWrapped = rebuiltWrapped
        cells = rebuilt
        rowOffset = 0
    }

    func snapshot() -> TerminalSnapshot {
        viewportSnapshot(scrollOffset: 0)
    }

    /// Composes a `rows`-tall viewport. With scrollOffset=0 the viewport is the
    /// active grid. With scrollOffset>0 the top N rows come from scrollback.
    func viewportSnapshot(scrollOffset requested: Int) -> TerminalSnapshot {
        let offset = max(0, min(requested, scrollbackCount))
        if offset == 0 {
            return TerminalSnapshot(
                cols: cols, rows: rows,
                cells: cells,
                rowOffset: rowOffset,
                rowWrapped: (0..<rows).map { rowWrapped[ringRow($0)] },
                cursorCol: cursorCol, cursorRow: cursorRow,
                cursorVisible: cursorVisible,
                scrollbackLines: scrollbackCount,
                scrollOffset: 0,
                title: title,
                prompts: visiblePrompts(offset: 0),
                scrolledRows: scrolledRows,
                currentDirectory: currentDirectory,
                usingAlt: usingAlt,
                links: linkURIs
            )
        }

        var viewport = [Cell]()
        viewport.reserveCapacity(cols * rows)
        var wrapped = [Bool]()
        wrapped.reserveCapacity(rows)

        // Scrollback rows: the offset most-recent rows are pushed UP off-screen,
        // so the rows we want are scrollback[count-offset ..< count] at the top
        // of the viewport.
        let firstScrollbackIdx = scrollbackCount - offset
        let scrollbackRowsShown = min(offset, rows)
        // Scrollback rows can be shorter than the current width; pad with one
        // blank rather than constructing a themed Cell per missing column.
        let padding = blankCell
        for i in 0..<scrollbackRowsShown {
            let row = scrollbackRow(firstScrollbackIdx + i)
            for c in 0..<cols {
                viewport.append(c < row.count ? row[c] : padding)
            }
            wrapped.append(scrollbackWrapped[scrollbackSlot(firstScrollbackIdx + i)])
        }

        // Grid rows: fill the rest of the viewport from the top of the active grid.
        let gridRowsShown = rows - scrollbackRowsShown
        for r in 0..<gridRowsShown {
            for c in 0..<cols {
                viewport.append(cells[rowBase(r) + c])
            }
            wrapped.append(rowWrapped[ringRow(r)])
        }

        // Cursor: only show when scrolled to the bottom; otherwise hide.
        return TerminalSnapshot(
            cols: cols, rows: rows,
            cells: viewport,
            rowOffset: 0,          // composed in logical order already
            rowWrapped: wrapped,
            cursorCol: cursorCol, cursorRow: cursorRow,
            cursorVisible: false,
            scrollbackLines: scrollbackCount,
            scrollOffset: offset,
            title: title,
            prompts: visiblePrompts(offset: offset),
            scrolledRows: scrolledRows,
            currentDirectory: currentDirectory,
            usingAlt: usingAlt,
            links: linkURIs
        )
    }

    // MARK: ParserSink

    func parserPrint(_ scalar: Unicode.Scalar) {
        let glyph = translate(scalar)
        putGlyph(glyph)
        lastPrinted = glyph
    }

    /// Applies the active G0/G1 designation. Only DEC special graphics ('0')
    /// remaps anything — that's what gives ncurses apps their box drawing when
    /// they don't emit the Unicode characters directly.
    private func translate(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        guard charsets[activeCharset] == 0x30,      // '0'
              scalar.value >= 0x5F, scalar.value <= 0x7E
        else { return scalar }
        return Self.decSpecialGraphics[Int(scalar.value - 0x5F)]
    }

    private func putGlyph(_ scalar: Unicode.Scalar) {
        let width = Self.displayWidth(scalar)
        if width == 0 {
            attachMark(scalar)
            return
        }
        // A grid narrower than the glyph has nowhere to put it. Only reachable
        // at cols == 1 with a double-width character — the wrap below lands
        // back on the last column, and the trailing half would then be written
        // past the end of the row (past the end of the grid entirely, on the
        // last row). xterm drops the character outright; so do we, before
        // anything has been mutated.
        guard width <= cols else { return }
        if cursorCol >= cols {
            if autoWrap {
                // The row being left continues on the next one; reflow rejoins
                // them on this flag. Only when real content crossed the edge,
                // though: zsh's PROMPT_SP pads a partial line with spaces purely
                // to reach column 0 of the row below, then prints a fresh prompt
                // there. Joining on that splices the prompt onto the tail of the
                // line above, and the shell's next redraw from column 0 wipes
                // that line out.
                //
                // The tell is blankness on *both* sides of the boundary — the
                // padding is spaces going out and spaces coming in. Text that
                // merely happens to wrap just after a space still has a real
                // glyph arriving, so it stays joined. Checked in place because
                // building a Cell() to compare against would take the theme
                // lock on every wrap.
                let last = cells[rowBase(cursorRow) + cols - 1]
                let leavingBlank = last.scalar == " " && last.attrs.isEmpty
                let arrivingBlank = scalar == " " && currentAttrs.isEmpty
                if !(leavingBlank && arrivingBlank) {
                    rowWrapped[ringRow(cursorRow)] = true
                }
                cursorCol = 0
                advanceRow()
            } else {
                // DECAWM off: the last column just keeps getting overwritten.
                cursorCol = cols - 1
            }
        }
        // A double-width glyph never straddles the right edge — it moves to the
        // next row whole, leaving the last column blank.
        if width == 2 && cursorCol == cols - 1 {
            guard autoWrap else { return }
            cells[rowBase(cursorRow) + cursorCol] = blankCell
            rowWrapped[ringRow(cursorRow)] = true
            cursorCol = 0
            advanceRow()
        }

        // Both halves have to be cleaned up before anything is written, or the
        // second cleanup would blank the head we just placed.
        clearOrphan(at: cursorCol)
        if width == 2 { clearOrphan(at: cursorCol + 1) }

        let inv = currentAttrs.contains(.inverse)
        let cell = Cell(
            scalar: scalar,
            fg: inv ? currentBg : currentFg,
            bg: inv ? currentFg : currentBg,
            attrs: currentAttrs,
            width: UInt8(width),
            link: currentLink
        )
        cells[rowBase(cursorRow) + cursorCol] = cell
        if width == 2 {
            // The trailing half keeps the head's colors so selection and
            // inverse video paint across the whole glyph.
            var tail = cell
            tail.scalar = " "
            tail.width = 0
            cells[rowBase(cursorRow) + cursorCol + 1] = tail
        }
        cursorCol += width
    }

    /// Overwriting half of a double-width pair strands the other half. Blank it
    /// so no fragment of the old glyph is left behind.
    private func clearOrphan(at col: Int) {
        guard col >= 0, col < cols else { return }
        let idx = rowBase(cursorRow) + col
        switch cells[idx].width {
        case 0:                                     // trailing half: head is left
            if col > 0 { cells[idx - 1] = blankCell }
        case 2:                                     // leading half: tail is right
            if col + 1 < cols { cells[idx + 1] = blankCell }
        default:
            break
        }
    }

    /// Combining marks don't get a cell of their own — that would shift the row
    /// out of step with what the child thinks it wrote. Compose the mark into
    /// the glyph it follows when Unicode has a precomposed form (e + ´ → é),
    /// and drop it when it doesn't.
    private func attachMark(_ mark: Unicode.Scalar) {
        var col = min(cursorCol, cols) - 1
        guard col >= 0 else { return }
        if cells[rowBase(cursorRow) + col].isContinuation, col > 0 { col -= 1 }
        let idx = rowBase(cursorRow) + col
        let composed = (String(cells[idx].scalar) + String(mark))
            .precomposedStringWithCanonicalMapping
            .unicodeScalars
        if composed.count == 1, let single = composed.first {
            cells[idx].scalar = single
        }
    }

    /// UAX #11 display width. Zero for marks that hang off the previous glyph,
    /// two for East Asian Wide/Fullwidth characters and emoji, one otherwise.
    static func displayWidth(_ scalar: Unicode.Scalar) -> Int {
        // Everything below the combining diacriticals is plain single-width
        // text, which is the overwhelming majority of what a terminal prints —
        // worth skipping the Unicode property lookups for.
        if scalar.value < 0x0300 { return 1 }

        switch scalar.properties.generalCategory {
        // Spacing marks (Mc) are deliberately absent: they take a column of
        // their own, unlike the marks that hang off the previous glyph.
        case .nonspacingMark, .enclosingMark, .format:
            // Zero-width joiners, variation selectors, combining accents.
            return scalar.value == 0x00AD ? 1 : 0   // soft hyphen does print
        default:
            break
        }
        if scalar.properties.isEmojiPresentation { return 2 }
        for range in Self.wideRanges where range.contains(scalar.value) { return 2 }
        return 1
    }

    /// East Asian Wide and Fullwidth blocks. Emoji are caught by the property
    /// check above, so this only has to cover the CJK/Hangul side.
    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F,        // Hangul Jamo
        0x2E80...0x303E,        // CJK radicals, Kangxi, punctuation
        0x3041...0x33FF,        // kana, Hangul compat, CJK squared forms
        0x3400...0x4DBF,        // CJK ext A
        0x4E00...0x9FFF,        // CJK unified
        0xA000...0xA4CF,        // Yi
        0xA960...0xA97F,        // Hangul Jamo ext A
        0xAC00...0xD7A3,        // Hangul syllables
        0xF900...0xFAFF,        // CJK compatibility ideographs
        0xFE10...0xFE19,        // vertical forms
        0xFE30...0xFE6F,        // CJK compatibility forms
        0xFF00...0xFF60,        // fullwidth ASCII
        0xFFE0...0xFFE6,        // fullwidth signs
        0x1F300...0x1F64F,      // pictographs and emoticons
        0x1F900...0x1F9FF,      // supplemental pictographs
        0x20000...0x2FFFD,      // CJK ext B+
        0x30000...0x3FFFD,      // CJK ext G+
    ]

    func parserExecute(_ control: UInt8) {
        switch control {
        case 0x07: onBell?()                         // BEL
        case 0x08:                                  // BS
            if cursorCol > 0 { cursorCol -= 1 }
        case 0x09:                                  // HT — next tab stop
            cursorCol = nextTabStop(after: cursorCol)
        case 0x0A, 0x0B, 0x0C:                      // LF/VT/FF
            advanceRow()
        case 0x0D:                                  // CR
            cursorCol = 0
        case 0x0E:                                  // SO — shift G1 in
            activeCharset = 1
        case 0x0F:                                  // SI — shift G0 in
            activeCharset = 0
        default:
            break
        }
    }

    func parserCSI(_ params: [Int], marker: UInt8?, intermediates: [UInt8], final: UInt8) {
        if !intermediates.isEmpty { return }
        switch marker {
        case 0x3F:                                  // '?' DEC private modes
            handlePrivateCSI(params: params, final: final)
            return
        case 0x3E:                                  // '>' secondary attributes
            if final == 0x63 { reply("\u{1B}[>0;10;1c") }
            return
        case .some:                                 // '<' / '=' — nothing we do
            return
        case nil:
            break
        }
        let p0 = params.first ?? 0
        switch final {
        case 0x41:                                  // 'A' CUU
            cursorRow = rowUp(from: cursorRow, by: max(1, p0))
            resolvePendingWrap()
        case 0x42:                                  // 'B' CUD
            cursorRow = rowDown(from: cursorRow, by: max(1, p0))
            resolvePendingWrap()
        case 0x45:                                  // 'E' CNL — down n, col 0
            cursorRow = rowDown(from: cursorRow, by: max(1, p0))
            cursorCol = 0
        case 0x46:                                  // 'F' CPL — up n, col 0
            cursorRow = rowUp(from: cursorRow, by: max(1, p0))
            cursorCol = 0
        case 0x43:                                  // 'C' CUF
            cursorCol = min(cols - 1, cursorCol + max(1, p0))
        case 0x44:                                  // 'D' CUB
            cursorCol = max(0, cursorCol - max(1, p0))
        case 0x47:                                  // 'G' CHA
            cursorCol = max(0, min(cols - 1, max(1, p0) - 1))
        case 0x48, 0x66:                            // 'H' / 'f' CUP
            let r = params.count >= 1 ? max(1, params[0]) : 1
            let c = params.count >= 2 ? max(1, params[1]) : 1
            cursorRow = absoluteRow(for: r)
            cursorCol = min(cols - 1, c - 1)
        case 0x64:                                  // 'd' VPA — absolute row
            cursorRow = absoluteRow(for: max(1, p0))
            resolvePendingWrap()
        case 0x49:                                  // 'I' CHT — forward tabs
            for _ in 0..<max(1, p0) { cursorCol = nextTabStop(after: cursorCol) }
        case 0x5A:                                  // 'Z' CBT — backward tabs
            for _ in 0..<max(1, p0) { cursorCol = previousTabStop(before: cursorCol) }
        case 0x62:                                  // 'b' REP — repeat last glyph
            if let last = lastPrinted {
                for _ in 0..<max(1, p0) { putGlyph(last) }
            }
        case 0x67:                                  // 'g' TBC — clear tab stops
            if p0 == 3 { tabStops.removeAll() } else { tabStops.remove(cursorCol) }
        case 0x63:                                  // 'c' DA1 — device attributes
            // VT220 with ANSI color, which is what xterm-256color implies.
            reply("\u{1B}[?62;22c")
        case 0x6E:                                  // 'n' DSR — device status
            switch p0 {
            case 5:
                reply("\u{1B}[0n")                   // "terminal OK"
            case 6:                                 // cursor position report
                let row = (originMode ? cursorRow - scrollTop : cursorRow) + 1
                let col = min(cursorCol, cols - 1) + 1
                reply("\u{1B}[\(row);\(col)R")
            default:
                break
            }
        case 0x50:                                  // 'P' DCH — delete chars
            deleteChars(max(1, p0))
        case 0x40:                                  // '@' ICH — insert blanks
            insertChars(max(1, p0))
        case 0x58:                                  // 'X' ECH — erase in place
            eraseChars(max(1, p0))
        case 0x4C:                                  // 'L' IL — insert lines
            insertLines(max(1, p0))
        case 0x4D:                                  // 'M' DL — delete lines
            deleteLines(max(1, p0))
        case 0x53:                                  // 'S' SU — scroll region up
            scrollUp(max(1, p0), top: scrollTop, bottom: scrollBottom)
        case 0x54:                                  // 'T' SD — scroll region down
            scrollDown(max(1, p0), top: scrollTop, bottom: scrollBottom)
        case 0x72:                                  // 'r' DECSTBM — set margins
            setScrollRegion(params)
        case 0x4A:                                  // 'J' ED
            eraseDisplay(mode: p0)
        case 0x4B:                                  // 'K' EL
            eraseLine(mode: p0)
        case 0x6D:                                  // 'm' SGR
            applySGR(params.isEmpty ? [0] : params)
        case 0x73:                                  // 's' SCOSC — save cursor
            saveCursor()
        case 0x75:                                  // 'u' SCORC — restore cursor
            restoreCursor()
        default:
            break
        }
    }

    func parserOSC(_ data: [UInt8], terminator: UInt8) {
        // OSC payload format: "<code>;<text>" (133 uses single-letter subcommands)
        guard let semi = data.firstIndex(of: 0x3B) else {
            // OSC with no semicolon — could be 133 with no payload, but our
            // shells always send the semicolon form. Ignore.
            return
        }
        var code = 0
        for b in data[..<semi] {
            guard (0x30...0x39).contains(b) else { return }
            code = code * 10 + Int(b - 0x30)
        }
        let payload = String(decoding: data[(semi + 1)...], as: UTF8.self)
        switch code {
        case 0, 2:                              // window title (and icon for 0)
            title = payload
        case 7:                                 // current working directory
            if let url = URL(string: payload), url.scheme == "file" {
                currentDirectory = url.path
            }
        case 8:                                 // hyperlink
            handleHyperlink(payload)
        case 9:                                 // iTerm2 desktop notification
            // OSC 9 ; <message> — body only, no title. The "9;4;…" form is
            // ConEmu/Windows-Terminal progress, not a notification — skip it.
            if !payload.isEmpty && !payload.hasPrefix("4;") {
                onNotify?("", payload)
            }
        case 777:                               // rxvt-unicode "notify" module
            // OSC 777 ; notify ; <title> ; <body> — body may contain ';'.
            let parts = payload.split(separator: ";", maxSplits: 2,
                                      omittingEmptySubsequences: false)
            if parts.count >= 2, parts[0] == "notify" {
                let title = String(parts[1])
                let body = parts.count >= 3 ? String(parts[2]) : ""
                onNotify?(title, body)
            }
        case 4:                                 // indexed palette color
            reportPaletteColors(payload, terminator: terminator)
        case 10, 11, 12:                        // foreground / background / cursor
            reportDynamicColors(from: code, payload: payload, terminator: terminator)
        case 133:
            handlePrompt133(payload)
        default:
            break
        }
    }

    /// OSC 10/11/12 with a "?" argument asks us to report the foreground,
    /// background or cursor color. Programs read the background answer to tell
    /// a light theme from a dark one; a terminal that stays silent gets treated
    /// as dark, which is why light themes looked wrong before we replied.
    ///
    /// Arguments are positional — each one after the OSC number steps to the
    /// next dynamic color, so `OSC 10;?;?` reports foreground then background.
    /// We only answer queries; requests to *change* a color are ignored, since
    /// the theme owns those.
    private func reportDynamicColors(from code: Int, payload: String, terminator: UInt8) {
        let theme = self.theme
        let args = payload.split(separator: ";", omittingEmptySubsequences: false)
        for (offset, arg) in args.enumerated() {
            guard arg == "?" else { continue }
            let color: SIMD4<Float>
            switch code + offset {
            case 10: color = theme.foreground
            case 11: color = theme.background
            case 12: color = theme.cursor
            default: continue
            }
            reply(oscReply("\(code + offset);\(xtermColorSpec(color))", terminator: terminator))
        }
    }

    /// OSC 4 ; <index> ; ? — report a palette entry. Arguments come in pairs,
    /// so one query can ask about several indices.
    private func reportPaletteColors(_ payload: String, terminator: UInt8) {
        let args = payload.split(separator: ";", omittingEmptySubsequences: false)
        var i = 0
        while i + 1 < args.count {
            if args[i + 1] == "?", let idx = Int(args[i]), (0...255).contains(idx) {
                let color = AnsiPalette.indexed256(idx, palette: theme.ansi)
                reply(oscReply("4;\(idx);\(xtermColorSpec(color))", terminator: terminator))
            }
            i += 2
        }
    }

    /// Answers carry whichever string terminator the query used: a program that
    /// reads up to a BEL would hang waiting on an `ESC \` reply.
    private func oscReply(_ body: String, terminator: UInt8) -> String {
        "\u{1B}]" + body + (terminator == 0x07 ? "\u{07}" : "\u{1B}\\")
    }

    /// xterm's `rgb:RRRR/GGGG/BBBB` reply form: 8-bit channels widened to 16.
    private func xtermColorSpec(_ c: SIMD4<Float>) -> String {
        func channel(_ f: Float) -> String {
            let v8 = UInt16((min(max(f, 0), 1) * 255).rounded())
            return String(format: "%04x", v8 &* 257)
        }
        return "rgb:\(channel(c.x))/\(channel(c.y))/\(channel(c.z))"
    }

    // MARK: OSC 8

    /// Schemes a hyperlink may carry. A program can put any string in an OSC 8
    /// and the text it labels is free to disagree with it, so anything that
    /// isn't plainly a document — `javascript:`, `data:`, some app's private
    /// scheme — never becomes clickable at all, rather than being caught later
    /// at the click.
    private static let linkSchemes: Set<String> = [
        "http", "https", "file", "mailto", "ftp", "ftps",
    ]

    /// OSC 8 ; params ; URI — opens a hyperlink covering every glyph printed
    /// until an OSC 8 with an empty URI closes it.
    ///
    /// Params are colon-separated key=value pairs. The only one with meaning is
    /// `id=`, which exists to rejoin runs the terminal would otherwise read as
    /// separate links; marking per contiguous run covers the case it was
    /// invented for — a link broken across a wrap — so it is parsed past and
    /// ignored.
    private func handleHyperlink(_ payload: String) {
        // Params end at the first ';'. A URI containing one has to
        // percent-encode it, so a single split is the whole grammar.
        guard let semi = payload.firstIndex(of: ";") else {
            // Malformed: no params/URI boundary at all. Close rather than
            // guess, so a broken sequence can't make the rest of the screen
            // one enormous link.
            currentLink = 0
            return
        }
        let uri = String(payload[payload.index(after: semi)...])
        currentLink = uri.isEmpty ? 0 : internLink(uri)
    }

    /// The id cells should carry for `uri`, or 0 when it can't be linked —
    /// which leaves the text on screen exactly as it was, just not clickable.
    private func internLink(_ uri: String) -> UInt16 {
        guard uri.utf8.count <= 4096, isLinkable(uri) else { return 0 }
        if let existing = linkIDs[uri] { return existing }
        if linkURIs.count >= linkSweepAt { sweepLinks() }
        // 0 is reserved and ids are 16-bit, so this is the ceiling. Declining
        // to link is the only safe way to reach it: recycling an id would
        // silently repoint scrollback that still carries it at a different URL.
        guard linkURIs.count < Int(UInt16.max) else { return 0 }
        linkURIs.append(uri)
        let id = UInt16(linkURIs.count)
        linkIDs[uri] = id
        return id
    }

    private func isLinkable(_ uri: String) -> Bool {
        guard let url = URL(string: uri),
              let scheme = url.scheme?.lowercased(),
              Self.linkSchemes.contains(scheme)
        else { return false }
        // A file URI names the host it lives on. Anything else is a path into
        // someone else's filesystem that would quietly resolve against ours.
        if scheme == "file" {
            return Self.localHostNames.contains(url.host?.lowercased() ?? "")
        }
        return true
    }

    /// Host names in a `file://` URI that mean this machine. An empty host is
    /// the spec's own answer, but GNU coreutils puts `gethostname()` in the
    /// links `ls --hyperlink` emits — accepting only the empty host would drop
    /// the most common producer of file links on the floor. Resolved once:
    /// this is read on the parser queue.
    private static let localHostNames: Set<String> = {
        var names: Set<String> = ["", "localhost"]
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0 else { return names }
        let host = String(cString: buf).lowercased()
        guard !host.isEmpty else { return names }
        names.insert(host)
        // `mac` and `mac.local` are the same machine.
        let bare = String(host.split(separator: ".").first ?? "")
        if !bare.isEmpty {
            names.insert(bare)
            names.insert(bare + ".local")
        }
        return names
    }()

    /// Drops targets no cell refers to any more and renumbers the rest, so a
    /// long-lived session doesn't walk the 16-bit id space up to its ceiling.
    /// Every grid that can hold a link has to be walked: the active cells, the
    /// primary grid stashed behind an alt screen, and all of scrollback.
    private func sweepLinks() {
        guard !linkURIs.isEmpty else { return }
        var live = [Bool](repeating: false, count: linkURIs.count + 1)
        for c in cells where c.link != 0 { live[Int(c.link)] = true }
        for c in stashedCells where c.link != 0 { live[Int(c.link)] = true }
        for row in scrollbackStore {
            for c in row where c.link != 0 { live[Int(c.link)] = true }
        }
        // The open link and the two saved slots have no cell yet but are about
        // to write one.
        for id in [currentLink, savedLink, stashedLink] where id != 0 {
            live[Int(id)] = true
        }

        var remap = [UInt16](repeating: 0, count: linkURIs.count + 1)
        var kept: [String] = []
        kept.reserveCapacity(linkURIs.count)
        for old in 1...linkURIs.count where live[old] {
            kept.append(linkURIs[old - 1])
            remap[old] = UInt16(kept.count)
        }
        guard kept.count < linkURIs.count else {
            // Everything is still referenced. Back off, or the next link
            // sweeps the whole of scrollback again for nothing.
            linkSweepAt = max(linkSweepAt, linkURIs.count) * 2
            return
        }

        for i in cells.indices where cells[i].link != 0 {
            cells[i].link = remap[Int(cells[i].link)]
        }
        for i in stashedCells.indices where stashedCells[i].link != 0 {
            stashedCells[i].link = remap[Int(stashedCells[i].link)]
        }
        for r in scrollbackStore.indices {
            for i in scrollbackStore[r].indices where scrollbackStore[r][i].link != 0 {
                scrollbackStore[r][i].link = remap[Int(scrollbackStore[r][i].link)]
            }
        }
        currentLink = remap[Int(currentLink)]
        savedLink   = remap[Int(savedLink)]
        stashedLink = remap[Int(stashedLink)]

        linkURIs = kept
        linkIDs.removeAll(keepingCapacity: true)
        for (i, uri) in kept.enumerated() { linkIDs[uri] = UInt16(i + 1) }
        linkSweepAt = max(4096, kept.count * 2)
    }

    private func handlePrompt133(_ payload: String) {
        // Payload formats:
        //   "A"           — start of prompt
        //   "B"           — end of prompt / start of command input
        //   "C"           — start of command output
        //   "D"           — end of command (no exit code)
        //   "D;<int>"     — end of command with exit code
        let parts = payload.split(separator: ";", omittingEmptySubsequences: false)
        guard let kind = parts.first else { return }
        switch kind {
        case "A":
            // Start a new prompt at the current row. If the most recent prompt
            // is at the same absolute line (e.g. precmd ran twice), replace it.
            let line = scrolledRows + cursorRow
            if let last = prompts.last, last.absoluteLine == line {
                return
            }
            prompts.append(Prompt(absoluteLine: line, exitCode: nil))
        case "B", "C":
            // We don't currently distinguish command region from output region.
            // A prompt is enough for the gutter dot and jump-to-prompt.
            break
        case "D":
            // Update the most recent prompt with the exit code of its command.
            if parts.count >= 2, let code = Int(parts[1]) {
                if !prompts.isEmpty {
                    prompts[prompts.count - 1].exitCode = code
                }
            }
        default:
            break
        }
    }

    private func visiblePrompts(offset: Int) -> [PromptMark] {
        guard !prompts.isEmpty else { return [] }
        let topAbs = scrolledRows - offset
        var out: [PromptMark] = []
        for p in prompts {
            let vr = p.absoluteLine - topAbs
            if vr >= 0 && vr < rows {
                out.append(PromptMark(viewportRow: vr, exitCode: p.exitCode))
            }
        }
        return out
    }

    /// Returns a new scrollOffset that brings the nearest prompt above
    /// (direction < 0) or below (direction > 0) the current viewport into view.
    /// Returns nil if no such prompt exists; direction > 0 with no prompt below
    /// returns 0 (snap to bottom).
    /// Remap any cell colors that came from the old theme's foreground,
    /// background, or ANSI palette to the new theme's equivalents. 24-bit and
    /// 256-color-cube cells (explicit user choices) are left alone.
    /// `ESC k <name> ST`. screen and tmux use it for the window name, which is
    /// the same thing OSC 0/2 set, so it lands in the same place and the
    /// sidebar picks it up.
    func parserWindowName(_ name: [UInt8]) {
        title = String(decoding: name, as: UTF8.self)
    }

    func parserDCSStart(_ params: [Int], intermediates: [UInt8], final: UInt8) {
        onDCSStart?(params, final)
    }

    func parserDCSPut(_ bytes: ArraySlice<UInt8>) {
        onDCSPut?(bytes)
    }

    func parserDCSEnd() {
        onDCSEnd?()
    }

    func applyThemeChange(from old: Theme, to new: Theme) {
        theme = new
        defaultFg = PackedColor(new.foreground)
        defaultBg = PackedColor(new.background)
        // Single map shared by fg and bg lookups. Any palette color can land
        // in either slot — when a cell is printed with inverse SGR (\e[7m)
        // we bake the swap at parse time, so cell.bg becomes the old fg and
        // cell.fg becomes the old bg.
        //
        // Some themes (Solarized) reuse their fg/bg hexes inside the ANSI 8-15
        // range. We populate ANSI first, then let fg/bg override on collision —
        // default-styled cells are common, explicit SGR 93/107 cells are rare,
        // so this prioritization keeps the common case right.
        var colorMap: [PackedColor: PackedColor] = [:]
        for i in 0..<min(old.ansi.count, new.ansi.count) {
            colorMap[PackedColor(old.ansi[i])] = PackedColor(new.ansi[i])
        }
        colorMap[PackedColor(old.foreground)] = PackedColor(new.foreground)
        colorMap[PackedColor(old.background)] = PackedColor(new.background)

        for i in 0..<cells.count {
            if let nfg = colorMap[cells[i].fg] { cells[i].fg = nfg }
            if let nbg = colorMap[cells[i].bg] { cells[i].bg = nbg }
        }
        for r in 0..<scrollbackCount {
            let slot = scrollbackSlot(r)
            for c in 0..<scrollbackStore[slot].count {
                if let nfg = colorMap[scrollbackStore[slot][c].fg] { scrollbackStore[slot][c].fg = nfg }
                if let nbg = colorMap[scrollbackStore[slot][c].bg] { scrollbackStore[slot][c].bg = nbg }
            }
        }
        for i in 0..<stashedCells.count {
            if let nfg = colorMap[stashedCells[i].fg] { stashedCells[i].fg = nfg }
            if let nbg = colorMap[stashedCells[i].bg] { stashedCells[i].bg = nbg }
        }

        // Also remap "current" / "saved" / "stashed" SGR state so the very next
        // glyph the shell prints picks up the new colors even without a reset.
        if let v = colorMap[currentFg]  { currentFg  = v }
        if let v = colorMap[currentBg]  { currentBg  = v }
        if let v = colorMap[savedFg]    { savedFg    = v }
        if let v = colorMap[savedBg]    { savedBg    = v }
        if let v = colorMap[stashedFg]  { stashedFg  = v }
        if let v = colorMap[stashedBg]  { stashedBg  = v }
    }

    /// Plain-substring or NSRegularExpression search across scrollback and the
    /// active grid. Returns matches in reading order (oldest first), each tagged
    /// with an absolute line number so it stays addressable as the grid scrolls.
    /// The whole buffer as plain text: scrollback followed by the active grid,
    /// one line per row with trailing blanks trimmed. Trailing empty lines (the
    /// unused grid below the cursor) are dropped. Used by "Copy All".
    func bufferText() -> String {
        var lines: [String] = []
        lines.reserveCapacity(scrollbackCount + rows)
        for i in 0..<scrollbackCount {
            lines.append(Self.rowText(scrollbackRow(i)))
        }
        for r in 0..<rows {
            lines.append(Self.rowText(gridRow(r)))
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// The row at an absolute line number — the same coordinate space as
    /// Prompt.absoluteLine and SearchMatch.absoluteLine. Scrollback holds
    /// [scrolledRows - scrollbackCount, scrolledRows); the active grid picks
    /// up from there. Returns nil for lines that have been trimmed off the top
    /// of history or sit past the bottom of the grid.
    private func row(atAbsolute line: Int) -> [Cell]? {
        let topOfHistory = scrolledRows - scrollbackCount
        if line < topOfHistory { return nil }
        if line < scrolledRows { return scrollbackRow(line - topOfHistory) }
        let r = line - scrolledRows
        guard r >= 0, r < rows else { return nil }
        return gridRow(r)
    }

    /// The span of the buffer that actually holds something, in absolute lines:
    /// the oldest retained line through the last non-blank one, with that
    /// line's last non-blank column. Returns nil for an empty buffer. Stopping
    /// at real content keeps Select All from dragging the empty rows below the
    /// prompt in as a run of trailing newlines.
    func contentBounds() -> (firstLine: Int, lastLine: Int, lastCol: Int)? {
        let firstLine = scrolledRows - scrollbackCount
        let lastPossible = scrolledRows + rows - 1
        var line = lastPossible
        while line >= firstLine {
            if let row = row(atAbsolute: line),
               let col = row.lastIndex(where: { !$0.isBlank }) {
                return (firstLine, line, col)
            }
            line -= 1
        }
        return nil
    }

    /// Text for an absolute-line range, spanning scrollback and the active
    /// grid. Lines that have aged out of scrollback are skipped, so a selection
    /// older than the buffer yields whatever survives of it.
    func text(from startLine: Int, startCol: Int, to endLine: Int, endCol: Int) -> String {
        guard endLine >= startLine else { return "" }
        var lines: [String] = []
        for line in startLine...endLine {
            guard let row = row(atAbsolute: line) else { continue }
            // Resize doesn't reflow history, so a scrollback row keeps whatever
            // width it was pushed at. Bound the range by this row rather than by
            // the current grid width, which may be wider or narrower.
            let firstCol = (line == startLine) ? max(0, startCol) : 0
            let lastCol  = min((line == endLine) ? endCol : row.count - 1, row.count - 1)
            var text = ""
            if firstCol <= lastCol {
                for c in firstCol...lastCol where !row[c].isContinuation {
                    text.unicodeScalars.append(row[c].scalar)
                }
            }
            // Strip trailing spaces from each row except the last (so single-line
            // selections preserve trailing spaces if you actually selected them).
            if line != endLine {
                while text.last == " " { text.removeLast() }
            }
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }

    private static func rowText(_ row: [Cell]) -> String {
        var line = ""
        line.reserveCapacity(row.count)
        for cell in row where !cell.isContinuation {
            line.unicodeScalars.append(cell.scalar)
        }
        while line.last == " " { line.removeLast() }
        return line
    }

    func search(query: String, regex useRegex: Bool, caseSensitive: Bool) -> [SearchMatch] {
        guard !query.isEmpty else { return [] }

        let pattern: NSRegularExpression?
        if useRegex {
            let opts: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
            guard let p = try? NSRegularExpression(pattern: query, options: opts) else {
                return []
            }
            pattern = p
        } else {
            pattern = nil
        }

        var matches: [SearchMatch] = []
        let topOfHistory = scrolledRows - scrollbackCount
        for i in 0..<scrollbackCount {
            scanRow(scrollbackRow(i), absLine: topOfHistory + i,
                    query: query, pattern: pattern,
                    caseSensitive: caseSensitive, into: &matches)
        }
        for r in 0..<rows {
            let row = gridRow(r)
            scanRow(row, absLine: scrolledRows + r,
                    query: query, pattern: pattern,
                    caseSensitive: caseSensitive, into: &matches)
        }
        return matches
    }

    private func scanRow(_ row: [Cell],
                         absLine: Int,
                         query: String,
                         pattern: NSRegularExpression?,
                         caseSensitive: Bool,
                         into matches: inout [SearchMatch]) {
        // String offsets can't double as column numbers any more: a double-width
        // glyph covers two columns, its trailing half contributes no text at
        // all, and an astral scalar is two UTF-16 units. Build the text and a
        // parallel map from each UTF-16 offset back to the column it came from.
        var line = ""
        var columnAt: [Int] = []
        line.reserveCapacity(row.count)
        columnAt.reserveCapacity(row.count)
        for (col, cell) in row.enumerated() where !cell.isContinuation {
            line.unicodeScalars.append(cell.scalar)
            for _ in 0..<UTF16.width(cell.scalar) { columnAt.append(col) }
        }

        /// Turns a UTF-16 range in `line` back into grid columns; endCol is
        /// exclusive, so a match ending on a wide glyph covers both its halves.
        func columns(for range: NSRange) -> (start: Int, end: Int)? {
            guard range.location < columnAt.count,
                  range.location + range.length - 1 < columnAt.count
            else { return nil }
            let startCol = columnAt[range.location]
            let lastCol = columnAt[range.location + range.length - 1]
            return (startCol, lastCol + max(1, Int(row[lastCol].width)))
        }
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)

        if let pattern = pattern {
            for m in pattern.matches(in: line, range: full) {
                if m.range.location == NSNotFound || m.range.length == 0 { continue }
                guard let c = columns(for: m.range) else { continue }
                matches.append(SearchMatch(absoluteLine: absLine,
                                           startCol: c.start, endCol: c.end))
            }
        } else {
            let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            var pos = 0
            while pos < ns.length {
                let searchRange = NSRange(location: pos, length: ns.length - pos)
                let r = ns.range(of: query, options: options, range: searchRange)
                if r.location == NSNotFound || r.length == 0 { break }
                if let c = columns(for: r) {
                    matches.append(SearchMatch(absoluteLine: absLine,
                                               startCol: c.start, endCol: c.end))
                }
                pos = r.location + r.length
            }
        }
    }

    func jumpToPromptOffset(direction: Int, from currentOffset: Int) -> Int? {
        guard !prompts.isEmpty else { return nil }
        let topAbs = scrolledRows - currentOffset
        let bottomAbs = topAbs + rows
        if direction < 0 {
            // strictly above the current top
            guard let target = prompts.last(where: { $0.absoluteLine < topAbs }) else { return nil }
            return max(0, scrolledRows - target.absoluteLine)
        } else {
            // strictly at or below the current bottom
            guard let target = prompts.first(where: { $0.absoluteLine >= bottomAbs }) else { return 0 }
            return max(0, scrolledRows - target.absoluteLine)
        }
    }

    func parserESC(_ final: UInt8, intermediates: [UInt8]) {
        // `ESC ( c` / `ESC ) c` designate the G0 / G1 charset slots.
        if intermediates.count == 1 {
            switch intermediates[0] {
            case 0x28: charsets[0] = final
            case 0x29: charsets[1] = final
            default: break
            }
            return
        }
        if !intermediates.isEmpty { return }
        switch final {
        case 0x48:                                  // 'H' HTS — set a tab stop
            tabStops.insert(min(cursorCol, cols - 1))
        case 0x37:                                  // '7' DECSC
            saveCursor()
        case 0x38:                                  // '8' DECRC
            restoreCursor()
        case 0x44:                                  // 'D' IND — index
            advanceRow()
        case 0x45:                                  // 'E' NEL — next line
            cursorCol = 0
            advanceRow()
        case 0x4D:                                  // 'M' RI — reverse index
            if cursorRow == scrollTop {
                scrollDown(1, top: scrollTop, bottom: scrollBottom)
            } else if cursorRow > 0 {
                cursorRow -= 1
            }
        case 0x63:                                  // 'c' RIS — full reset
            fullReset()
        default:
            break
        }
    }

    // MARK: private CSI

    private func handlePrivateCSI(params: [Int], final: UInt8) {
        let set = (final == 0x68)                   // 'h' = set, 'l' = reset
        for p in params.isEmpty ? [0] : params {
            switch p {
            case 6:                                 // DECOM — origin mode
                originMode = set
                cursorRow = set ? scrollTop : 0
                cursorCol = 0
            case 7:                                 // DECAWM — autowrap
                autoWrap = set
            case 9:
                setMouseTracking(.x10, on: set)
            case 25:
                cursorVisible = set
            case 1000:
                setMouseTracking(.normal, on: set)
            case 1002:
                setMouseTracking(.buttonEvent, on: set)
            case 1003:
                setMouseTracking(.anyEvent, on: set)
            case 1004:
                reportFocus = set
            case 1006:
                mouseEncoding = set ? .sgr : .x10
            case 1007:
                alternateScroll = set
            case 2004:
                bracketedPaste = set
            case 2026:                              // synchronized output
                syncUpdateDeadline = set
                    ? CFAbsoluteTimeGetCurrent() + Self.syncUpdateTimeout
                    : nil
            case 47, 1047:
                set ? enterAltScreen(clear: true) : exitAltScreen()
            case 1048:
                set ? saveCursor() : restoreCursor()
            case 1049:
                if set {
                    saveCursor()
                    enterAltScreen(clear: true)
                } else {
                    exitAltScreen()
                    restoreCursor()
                }
            default:
                break
            }
        }
    }

    // MARK: cursor save/restore

    private func saveCursor() {
        savedCursor = (cursorCol, cursorRow)
        savedFg = currentFg
        savedBg = currentBg
        savedAttrs = currentAttrs
        savedLink = currentLink
    }

    private func restoreCursor() {
        cursorCol = min(savedCursor.col, cols - 1)
        cursorRow = min(savedCursor.row, rows - 1)
        currentFg = savedFg
        currentBg = savedBg
        currentAttrs = savedAttrs
        currentLink = savedLink
    }

    // MARK: alt screen

    private func enterAltScreen(clear: Bool) {
        if usingAlt { return }
        // ?1007 only means anything while the alt screen is up, so each
        // full-screen session starts from our default. Without this an app
        // that turns alternate scroll off on its way out (codex does) leaves
        // the wheel dead in the *next* one — and teardown order isn't
        // reliable enough to undo it when the alt screen is left instead.
        alternateScroll = true
        // Stash the primary grid in logical order. A ring offset kept beside
        // it would have to survive a resize, which reflows stashedCells and
        // would leave the offset describing the old geometry.
        normalizeRowOffset()
        stashedCells = cells
        stashedRowWrapped = rowWrapped
        stashedCursor = (cursorCol, cursorRow)
        stashedFg = currentFg
        stashedBg = currentBg
        stashedAttrs = currentAttrs
        stashedLink = currentLink
        cells = Array(repeating: blankCell, count: cols * rows)
        rowWrapped = Array(repeating: false, count: rows)
        rowOffset = 0
        cursorCol = 0
        cursorRow = 0
        let theme = self.theme
        currentFg = PackedColor(theme.foreground)
        currentBg = PackedColor(theme.background)
        currentAttrs = []
        currentLink = 0
        scrollTop = 0
        scrollBottom = rows - 1
        usingAlt = true
    }

    private func exitAltScreen() {
        if !usingAlt { return }
        cells = stashedCells
        rowWrapped = stashedRowWrapped
        rowOffset = 0          // stashed already normalized, see enterAltScreen
        stashedCells = []
        stashedRowWrapped = []
        cursorCol = min(stashedCursor.col, cols - 1)
        cursorRow = min(stashedCursor.row, rows - 1)
        currentFg = stashedFg
        currentBg = stashedBg
        currentAttrs = stashedAttrs
        currentLink = stashedLink
        scrollTop = 0
        scrollBottom = rows - 1
        usingAlt = false
    }

    private func fullReset() {
        cells = Array(repeating: blankCell, count: cols * rows)
        rowWrapped = Array(repeating: false, count: rows)
        rowOffset = 0
        cursorCol = 0
        cursorRow = 0
        let theme = self.theme
        currentFg = PackedColor(theme.foreground)
        currentBg = PackedColor(theme.background)
        currentAttrs = []
        currentLink = 0
        savedLink = 0
        stashedLink = 0
        cursorVisible = true
        scrollTop = 0
        scrollBottom = rows - 1
        syncUpdateDeadline = nil
        autoWrap = true
        originMode = false
        bracketedPaste = false
        reportFocus = false
        mouseTracking = .off
        mouseEncoding = .x10
        alternateScroll = true
        charsets = [0x42, 0x42]
        activeCharset = 0
        tabStops = Self.defaultTabStops(cols: cols)
        lastPrinted = nil
    }

    // MARK: scrolling / erase

    /// After a glyph lands in the last column, cursorCol sits at `cols` — the
    /// deferred-wrap state, so the wrap only happens if another glyph arrives.
    /// Any cursor movement cancels it (xterm clears its last-column flag the
    /// same way); without this a row-only move would leave the state armed and
    /// the next glyph would wrap onto the row below the one just addressed.
    private func resolvePendingWrap() {
        cursorCol = min(cursorCol, cols - 1)
    }

    private func advanceRow() {
        if cursorRow == scrollBottom {
            scrollUp(1, top: scrollTop, bottom: scrollBottom)
        } else if cursorRow < rows - 1 {
            // Below the bottom margin the cursor just sits there: a line feed
            // outside the region must not scroll the screen.
            cursorRow += 1
        }
    }

    private func reply(_ s: String) {
        onReply?(Array(s.utf8))
    }

    /// A mode is only cleared by the same mode that set it, so an app resetting
    /// ?1000 can't silently cancel the ?1002 tracking another one turned on.
    private func setMouseTracking(_ mode: MouseTracking, on: Bool) {
        if on {
            mouseTracking = mode
        } else if mouseTracking == mode {
            mouseTracking = .off
        }
    }

    /// Resolves a 1-based row from CUP/VPA. Under origin mode rows are counted
    /// from the top margin and can't escape the scrolling region.
    private func absoluteRow(for oneBased: Int) -> Int {
        if originMode {
            return min(scrollBottom, scrollTop + oneBased - 1)
        }
        return max(0, min(rows - 1, oneBased - 1))
    }

    private static func defaultTabStops(cols: Int) -> Set<Int> {
        var stops = Set<Int>()
        var c = 8
        while c < cols {
            stops.insert(c)
            c += 8
        }
        return stops
    }

    private func nextTabStop(after col: Int) -> Int {
        var best: Int?
        for stop in tabStops where stop > col {
            if best == nil || stop < best! { best = stop }
        }
        return min(cols - 1, best ?? cols - 1)
    }

    private func previousTabStop(before col: Int) -> Int {
        var best: Int?
        for stop in tabStops where stop < col {
            if best == nil || stop > best! { best = stop }
        }
        return max(0, best ?? 0)
    }

    /// DEC special graphics, covering 0x5F...0x7E. Everything else in the set
    /// is plain ASCII, so the table only needs this window.
    private static let decSpecialGraphics: [Unicode.Scalar] = [
        " ", "\u{25C6}", "\u{2592}", "\u{2409}", "\u{240C}", "\u{240D}", "\u{240A}",
        "\u{00B0}", "\u{00B1}", "\u{2424}", "\u{240B}", "\u{2518}", "\u{2510}",
        "\u{250C}", "\u{2514}", "\u{253C}", "\u{23BA}", "\u{23BB}", "\u{2500}",
        "\u{23BC}", "\u{23BD}", "\u{251C}", "\u{2524}", "\u{2534}", "\u{252C}",
        "\u{2502}", "\u{2264}", "\u{2265}", "\u{03C0}", "\u{2260}", "\u{00A3}",
        "\u{00B7}",
    ]

    /// CUU / CPL. A cursor already inside the region stops at the top margin;
    /// one above it stops at row 0.
    private func rowUp(from row: Int, by n: Int) -> Int {
        max(row >= scrollTop ? scrollTop : 0, row - n)
    }

    /// CUD / CNL — the mirror of `rowUp` against the bottom margin.
    private func rowDown(from row: Int, by n: Int) -> Int {
        min(row <= scrollBottom ? scrollBottom : rows - 1, row + n)
    }

    /// Blanks `count` cells starting at `index`, building the blank once rather
    /// than per cell. The blank still leaves its foreground unset, and Cell.init
    /// consults the theme for a missing colour — a lock plus a Theme copy — so
    /// building one per column made a full-screen erase cost one lock
    /// acquisition per cell.
    private func blankCells(from index: Int, count: Int) {
        guard count > 0 else { return }
        // Back-colour erase (BCE): erased cells take the *current* SGR
        // background, not the theme's. xterm-256color advertises `bce`, so
        // apps paint a band by setting a background and erasing rather than
        // writing spaces across it — ratatui, vim status lines and htop all
        // do. Blanking to the theme background left those bands unpainted
        // except for whatever cells were written explicitly.
        // Foreground stays the default: a blank has no glyph, and carrying
        // the current one would tint it if the cell were later inverted. It is
        // this buffer's default, not the app's — leaving `fg` out here would
        // send `Cell.init` to `ThemeStore.currentTheme` and paint a
        // profile-themed tab's erased cells from the wrong palette (and take
        // the theme lock on every erase and every scrolled-in row).
        let erased = Cell(fg: defaultFg, bg: currentBg)
        cells.withUnsafeMutableBufferPointer { buf in
            (buf.baseAddress! + index).update(repeating: erased, count: count)
        }
    }

    /// Moves `count` cells from `src` to `dst`. Cell is trivially copyable (see
    /// its `width` note), so this is a memmove rather than a cell-at-a-time
    /// loop — the ranges are allowed to overlap, and every caller's do.
    private func moveCells(from src: Int, to dst: Int, count: Int) {
        guard count > 0 else { return }
        cells.withUnsafeMutableBufferPointer { buf in
            let p = buf.baseAddress!
            memmove(p + dst, p + src, count * MemoryLayout<Cell>.stride)
        }
    }

    /// Moves rows [top, bottom] up by `n`, blanking what opens up at the bottom
    /// margin. Only a full-screen region on the primary screen feeds scrollback
    /// — a narrower one discards what scrolls off, which is what xterm does —
    /// and DL passes `toScrollback: false` since deleted lines aren't history.
    private func scrollUp(_ n: Int, top: Int, bottom: Int, toScrollback: Bool = true) {
        guard top >= 0, bottom < rows, top <= bottom else { return }
        let lines = min(n, bottom - top + 1)
        guard lines > 0 else { return }

        // A line only leaves the screen for good when the region starts at the
        // top, but the bottom margin has nothing to do with it: an app that
        // parks its live UI at the bottom and scrolls the region above it
        // (CSI 1;8r — ratatui's inline viewport, which is how codex emits
        // finished output) is feeding us history exactly like a full-screen
        // scroll does. Requiring the whole screen here dropped it on the floor,
        // leaving nothing to scroll back to.
        if toScrollback && !usingAlt && top == 0 {
            pushToScrollback(lines)
        }
        if top == 0 && bottom == rows - 1 {
            // Whole-grid scroll: the ordinary case, and the only shape the ring
            // can express. Every row moves at once by rotating the offset, so a
            // line of output costs one blanked row instead of a copy of the
            // entire grid.
            rowOffset += lines
            if rowOffset >= rows { rowOffset -= rows }
            for r in (rows - lines)..<rows {
                blankCells(from: rowBase(r), count: cols)
                rowWrapped[ringRow(r)] = false
            }
            return
        }
        // A margin-bounded region can't rotate — that would drag the rows
        // outside the margins along with it — so those move a row at a time.
        // Rows are no longer adjacent in ring order, hence the per-row move.
        let shiftEnd = bottom - lines
        if shiftEnd >= top {
            for r in top...shiftEnd {
                moveCells(from: rowBase(r + lines), to: rowBase(r), count: cols)
                rowWrapped[ringRow(r)] = rowWrapped[ringRow(r + lines)]
            }
        }
        for r in (bottom - lines + 1)...bottom {
            blankCells(from: rowBase(r), count: cols)
            rowWrapped[ringRow(r)] = false
        }
    }

    /// Moves rows [top, bottom] down by `n`, blanking what opens up at the top
    /// margin. Nothing is ever saved: what falls off the bottom is gone.
    private func scrollDown(_ n: Int, top: Int, bottom: Int) {
        guard top >= 0, bottom < rows, top <= bottom else { return }
        let lines = min(n, bottom - top + 1)
        guard lines > 0 else { return }

        if top == 0 && bottom == rows - 1 {
            rowOffset -= lines
            if rowOffset < 0 { rowOffset += rows }   // lines <= rows, so one wrap
            for r in 0..<lines {
                blankCells(from: rowBase(r), count: cols)
                rowWrapped[ringRow(r)] = false
            }
            return
        }
        let shiftStart = top + lines
        if shiftStart <= bottom {
            // Descending, so a row is never overwritten before it is read.
            for r in stride(from: bottom, through: shiftStart, by: -1) {
                moveCells(from: rowBase(r - lines), to: rowBase(r), count: cols)
                rowWrapped[ringRow(r)] = rowWrapped[ringRow(r - lines)]
            }
        }
        for r in top...(top + lines - 1) {
            blankCells(from: rowBase(r), count: cols)
            rowWrapped[ringRow(r)] = false
        }
    }

    private func pushToScrollback(_ lines: Int) {
        for r in 0..<lines { pushScrollbackRow(r) }
        scrolledRows += lines
        // Drop prompts that have fallen out of scrollback.
        let topOfHistory = scrolledRows - scrollbackCount
        if let firstKeep = prompts.firstIndex(where: { $0.absoluteLine >= topOfHistory }),
           firstKeep > 0 {
            prompts.removeFirst(firstKeep)
        } else if !prompts.isEmpty,
                  prompts.last!.absoluteLine < topOfHistory {
            prompts.removeAll()
        }
    }

    /// Moves one grid row into scrollback, recycling the oldest row's storage
    /// once the ring is full.
    private func pushScrollbackRow(_ row: Int) {
        guard maxScrollback > 0 else { return }
        let base = rowBase(row)
        if scrollbackCount < maxScrollback {
            scrollbackStore.append(gridRow(row))
            scrollbackWrapped.append(rowWrapped[ringRow(row)])
            scrollbackCount += 1
            return
        }
        // Full: the oldest slot becomes the newest. Dropping the store's own
        // reference first is what leaves `recycled` uniquely referenced, so the
        // append reuses its buffer rather than allocating. If a caller is still
        // holding that row the copy-on-write simply happens as it always did.
        let slot = scrollbackStart
        var recycled = scrollbackStore[slot]
        scrollbackStore[slot] = []
        recycled.removeAll(keepingCapacity: true)
        cells.withUnsafeBufferPointer { src in
            recycled.append(contentsOf: UnsafeBufferPointer(start: src.baseAddress! + base,
                                                            count: cols))
        }
        scrollbackStore[slot] = recycled
        scrollbackWrapped[slot] = rowWrapped[ringRow(row)]
        scrollbackStart = slot + 1 == scrollbackStore.count ? 0 : slot + 1
    }

    /// DECSTBM. Margins arrive 1-based and inclusive; a region shorter than two
    /// rows is ignored, per DEC. Setting margins homes the cursor.
    private func setScrollRegion(_ params: [Int]) {
        let requestedTop = params.count >= 1 && params[0] > 0 ? params[0] - 1 : 0
        let requestedBottom = params.count >= 2 && params[1] > 0 ? params[1] - 1 : rows - 1
        let top = max(0, min(rows - 1, requestedTop))
        let bottom = max(0, min(rows - 1, requestedBottom))
        guard top < bottom else { return }
        scrollTop = top
        scrollBottom = bottom
        cursorRow = 0
        cursorCol = 0
    }

    private func eraseDisplay(mode: Int) {
        switch mode {
        case 0:
            eraseLine(mode: 0)
            if cursorRow + 1 < rows {
                for r in (cursorRow + 1)..<rows {
                    blankCells(from: rowBase(r), count: cols)
                    rowWrapped[ringRow(r)] = false
                }
            }
        case 1:
            for r in 0..<cursorRow {
                blankCells(from: rowBase(r), count: cols)
                rowWrapped[ringRow(r)] = false
            }
            blankCells(from: rowBase(cursorRow), count: min(cursorCol, cols - 1) + 1)
        case 2:
            // What was on screen goes to history rather than being dropped.
            // This is the ED that Ctrl+L is built from, and dropping it left a
            // hole: scrolling up jumped straight past the screenful that had
            // just been cleared. Terminal.app, iTerm2 and kitty all keep it.
            pushScreenToScrollback()
            // Every row is cleared, so ring order doesn't matter here.
            blankCells(from: 0, count: cells.count)
            for i in rowWrapped.indices { rowWrapped[i] = false }
            holdForRepaintAfterErase()
        case 3:
            // xterm's "erase saved lines": the scrollback goes, the grid stays.
            // This is how `clear` empties history, and how codex rebuilds its
            // transcript on resize — purge, then re-emit at the new width.
            // Treating it as another screen clear left every pre-resize copy
            // in place, one more per drag.
            clearScrollback()
        default:
            break
        }
    }

    /// Moves the visible grid into scrollback ahead of a full-screen erase, so
    /// what was on screen stays reachable by scrolling.
    ///
    /// Order is what keeps this compatible with the apps that erase to repaint.
    /// codex's resize emits `H 2J 3J H` — the push lands in history and the
    /// `3J` right behind it takes the whole lot away again, so no stale copy
    /// survives a drag. `clear(1)` emits the reverse, `3J H 2J`: history goes
    /// first and the screenful the user was looking at is what remains. Ctrl+L
    /// sends the `2J` alone and keeps everything.
    ///
    /// Trailing blank rows are left behind — an app that erases an already
    /// erased screen would otherwise file a screenful of nothing on every
    /// repaint — and the alt screen never feeds history at all.
    private func pushScreenToScrollback() {
        guard !usingAlt else { return }
        // Built once, and from the same two colours `blankCells` writes: this
        // is compared field-by-field against real cells, so a template whose
        // `fg` came from the app's theme rather than this buffer's would never
        // match in a profile-themed tab, and every repaint would file a
        // screenful of blanks into history.
        let blank = Cell(fg: defaultFg, bg: currentBg)
        var last = -1
        for r in 0..<rows where !rowIsBlank(r, blank: blank) { last = r }
        guard last >= 0 else { return }
        pushToScrollback(last + 1)
    }

    /// True when every cell in `row` is what an erase to the current
    /// background would have left. Colour counts: a band with no text in it is
    /// still something the user saw, which is why this compares the same
    /// fields `paintedCount` does rather than looking only for glyphs.
    private func rowIsBlank(_ row: Int, blank: Cell) -> Bool {
        let base = rowBase(row)
        for c in 0..<cols {
            let cell = cells[base + c]
            guard cell.scalar == blank.scalar, cell.width == blank.width,
                  cell.attrs == blank.attrs, cell.fg == blank.fg, cell.bg == blank.bg
            else { return false }
        }
        return true
    }

    /// Drops every saved row. `scrolledRows` keeps counting so absolute line
    /// numbers taken before the purge — a selection, a prompt mark — still name
    /// the same line; they just no longer resolve to anything.
    private func clearScrollback() {
        scrollbackStore.removeAll(keepingCapacity: true)
        scrollbackWrapped.removeAll(keepingCapacity: true)
        scrollbackStart = 0
        scrollbackCount = 0
    }

    /// DCH: deletes `count` cells at the cursor, shifting the rest of the line
    /// left and backfilling the tail with blanks.
    private func deleteChars(_ count: Int) {
        let n = min(count, cols - cursorCol)
        guard n > 0 else { return }
        let base = rowBase(cursorRow)
        moveCells(from: base + cursorCol + n, to: base + cursorCol,
                  count: cols - cursorCol - n)
        blankCells(from: base + cols - n, count: n)
    }

    /// ICH: shifts the rest of the line right by `count`, dropping whatever
    /// falls off the end, and blanks the gap left at the cursor.
    private func insertChars(_ count: Int) {
        let col = min(cursorCol, cols - 1)
        let n = min(count, cols - col)
        guard n > 0 else { return }
        let base = rowBase(cursorRow)
        moveCells(from: base + col, to: base + col + n, count: cols - col - n)
        blankCells(from: base + col, count: n)
    }

    /// ECH: blanks `count` cells from the cursor without shifting the line.
    private func eraseChars(_ count: Int) {
        let col = min(cursorCol, cols - 1)
        let n = min(count, cols - col)
        guard n > 0 else { return }
        blankCells(from: rowBase(cursorRow) + col, count: n)
    }

    /// IL / DL. Both are no-ops outside the scrolling region, and both scroll
    /// only from the cursor row down to the bottom margin.
    private func insertLines(_ count: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        scrollDown(count, top: cursorRow, bottom: scrollBottom)
        cursorCol = 0
    }

    private func deleteLines(_ count: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        scrollUp(count, top: cursorRow, bottom: scrollBottom, toScrollback: false)
        cursorCol = 0
    }

    private func eraseLine(mode: Int) {
        switch mode {
        case 0:
            blankCells(from: rowBase(cursorRow) + cursorCol, count: cols - cursorCol)
            // The row no longer reaches the right edge, so it no longer wraps.
            rowWrapped[ringRow(cursorRow)] = false
        case 1:
            blankCells(from: rowBase(cursorRow), count: min(cursorCol, cols - 1) + 1)
        case 2:
            blankCells(from: rowBase(cursorRow), count: cols)
            rowWrapped[ringRow(cursorRow)] = false
        default:
            break
        }
    }

    // MARK: SGR

    private func applySGR(_ params: [Int]) {
        let theme = self.theme
        let palette = theme.ansi
        var i = 0
        while i < params.count {
            let p = params[i]
            switch p {
            case 0:
                currentFg = PackedColor(theme.foreground)
                currentBg = PackedColor(theme.background)
                currentAttrs = []
            case 1:  currentAttrs.insert(.bold)
            case 2:  currentAttrs.insert(.faint)
            case 3:  currentAttrs.insert(.italic)
            case 4:  currentAttrs.insert(.underline)
            case 7:  currentAttrs.insert(.inverse)
            case 22: currentAttrs.remove(.bold); currentAttrs.remove(.faint)
            case 23: currentAttrs.remove(.italic)
            case 24: currentAttrs.remove(.underline)
            case 27: currentAttrs.remove(.inverse)
            case 30...37:
                currentFg = PackedColor(palette[p - 30])
            case 38:
                if let color = readExtendedColor(params, index: &i, palette: palette) { currentFg = PackedColor(color) }
            case 39:
                currentFg = PackedColor(theme.foreground)
            case 40...47:
                currentBg = PackedColor(palette[p - 40])
            case 48:
                if let color = readExtendedColor(params, index: &i, palette: palette) { currentBg = PackedColor(color) }
            case 49:
                currentBg = PackedColor(theme.background)
            case 90...97:
                currentFg = PackedColor(palette[p - 90 + 8])
            case 100...107:
                currentBg = PackedColor(palette[p - 100 + 8])
            default:
                break
            }
            i += 1
        }
    }

    private func readExtendedColor(_ params: [Int],
                                   index: inout Int,
                                   palette: [SIMD4<Float>]) -> SIMD4<Float>? {
        guard index + 1 < params.count else { return nil }
        let mode = params[index + 1]
        if mode == 5, index + 2 < params.count {
            let n = params[index + 2]
            index += 2
            return AnsiPalette.indexed256(n, palette: palette)
        }
        if mode == 2, index + 4 < params.count {
            let r = Float(params[index + 2]) / 255.0
            let g = Float(params[index + 3]) / 255.0
            let b = Float(params[index + 4]) / 255.0
            index += 4
            return SIMD4<Float>(r, g, b, 1)
        }
        return nil
    }

    // MARK: helpers

    /// Rejoins every wrapped line across scrollback and the primary grid,
    /// re-splits it at `newCols`, then hands the last `newRows` rows back as
    /// the grid and keeps the rest as history.
    ///
    /// This renumbers absolute lines — a line spanning three rows at 40 columns
    /// spans one at 120 — so prompt markers are carried across by the logical
    /// line they sit on rather than by their old index.
    private func reflowPrimary(grid: [Cell], wrapped: [Bool],
                               cursorCol: Int, cursorRow: Int,
                               newCols: Int, newRows: Int)
        -> (cells: [Cell], wrapped: [Bool], cursorCol: Int, cursorRow: Int) {

        let blank = blankCell

        // 1. Every primary row that exists, oldest first.
        struct SourceRow { let cells: [Cell]; let wrapped: Bool; let absolute: Int }
        var source: [SourceRow] = []
        source.reserveCapacity(scrollbackCount + rows)
        let topOfHistory = scrolledRows - scrollbackCount
        for i in 0..<scrollbackCount {
            source.append(SourceRow(cells: scrollbackRow(i),
                                    wrapped: scrollbackWrapped[scrollbackSlot(i)],
                                    absolute: topOfHistory + i))
        }
        for r in 0..<rows {
            let base = r * cols          // normalizeRowOffset ran before the call
            source.append(SourceRow(cells: Array(grid[base ..< base + cols]),
                                    wrapped: wrapped[r],
                                    absolute: scrolledRows + r))
        }

        // 2. Join wrapped runs into logical lines. `used` is the meaningful
        //    length; the array behind it may be longer (trailing blanks) and
        //    that is fine — the grid copy truncates and scrollback tolerates
        //    any width, so a line that already fits keeps its storage instead
        //    of being rebuilt. That fast path is most of the buffer, and doing
        //    every row the slow way cost ~18ms a step on a live window drag.
        struct Logical { var cells: [Cell]; var used: Int }
        var logicals: [Logical] = []
        logicals.reserveCapacity(source.count)
        var absoluteToLogical: [Int: Int] = [:]
        absoluteToLogical.reserveCapacity(source.count)
        let cursorAbsolute = scrolledRows + cursorRow
        var cursorLogical = 0
        var cursorOffset = 0

        var i = 0
        while i < source.count {
            let first = source[i]
            if !first.wrapped {
                let used = Self.trimmedCount(first.cells, blank: blank)
                if used <= newCols {
                    absoluteToLogical[first.absolute] = logicals.count
                    if first.absolute == cursorAbsolute {
                        cursorLogical = logicals.count
                        cursorOffset = cursorCol
                    }
                    logicals.append(Logical(cells: first.cells, used: used))
                    i += 1
                    continue
                }
            }
            // Slow path: rejoin the run. A wrapped row is full by definition,
            // so it contributes every column; only the row ending the line has
            // trailing blanks worth dropping.
            var joined: [Cell] = []
            var j = i
            while true {
                let row = source[j]
                absoluteToLogical[row.absolute] = logicals.count
                if row.absolute == cursorAbsolute {
                    cursorLogical = logicals.count
                    cursorOffset = joined.count + cursorCol
                }
                if row.wrapped && j + 1 < source.count {
                    joined.append(contentsOf: row.cells)
                    j += 1
                } else {
                    joined.append(contentsOf: row.cells[0 ..< Self.trimmedCount(row.cells, blank: blank)])
                    break
                }
            }
            logicals.append(Logical(cells: joined, used: joined.count))
            i = j + 1
        }

        // 3. Re-split each logical line at the new width.
        var rebuilt: [(cells: [Cell], wrapped: Bool)] = []
        rebuilt.reserveCapacity(logicals.count)
        var logicalFirstRow = [Int](repeating: 0, count: logicals.count)
        var newCursorRowIndex = 0
        var newCursorCol = 0

        for (li, line) in logicals.enumerated() {
            logicalFirstRow[li] = rebuilt.count

            if line.used <= newCols {
                rebuilt.append((cells: line.cells, wrapped: false))
                if li == cursorLogical {
                    newCursorRowIndex = rebuilt.count - 1
                    newCursorCol = max(0, min(cursorOffset, newCols - 1))
                }
                continue
            }

            var starts: [Int] = []
            var lengths: [Int] = []
            var pos = 0
            repeat {
                var take = min(newCols, line.used - pos)
                // A double-width glyph never straddles the edge: if the cut
                // would land between a head and the trailing half it reserved,
                // push the whole glyph to the next row.
                if take == newCols, pos + take < line.used,
                   line.cells[pos + take].width == 0 {
                    take -= 1
                }
                starts.append(pos)
                lengths.append(max(0, take))
                pos += max(take, 1)
            } while pos < line.used

            for (k, start) in starts.enumerated() {
                rebuilt.append((cells: Array(line.cells[start ..< start + lengths[k]]),
                                wrapped: k < starts.count - 1))
            }

            guard li == cursorLogical else { continue }
            var placed = false
            for (k, start) in starts.enumerated() {
                guard !placed, cursorOffset < start + lengths[k] || k == starts.count - 1 else { continue }
                newCursorRowIndex = logicalFirstRow[li] + k
                newCursorCol = max(0, min(cursorOffset - start, newCols - 1))
                placed = true
            }
            if !placed { newCursorRowIndex = logicalFirstRow[li] }
        }

        // 4. Trailing blank rows are grid padding, not content. Keeping them
        //    would push real text up into scrollback every time a line
        //    re-split into more rows than it used to occupy, so the screen
        //    would creep upward on each narrowing. Cut back to the last row
        //    carrying something, or the cursor's row if it sits below that.
        var lastMeaningful = -1
        for (k, row) in rebuilt.enumerated()
        where Self.paintedCount(row.cells, blank: blank) > 0 {
            lastMeaningful = k
        }
        lastMeaningful = max(lastMeaningful, newCursorRowIndex)
        if lastMeaningful + 1 < rebuilt.count {
            rebuilt.removeSubrange((lastMeaningful + 1)...)
        }

        // 5. The tail is the grid; everything above it is history, capped.
        //    Scrollback rows are stored at whatever width they came out at —
        //    viewportSnapshot pads short ones — so no row is copied to fit.
        let total = rebuilt.count
        let gridStart = max(0, total - newRows)
        let keep = min(gridStart, maxScrollback)
        let dropped = gridStart - keep

        scrollbackStore = []
        scrollbackWrapped = []
        scrollbackStore.reserveCapacity(keep)
        scrollbackWrapped.reserveCapacity(keep)
        for k in dropped..<gridStart {
            scrollbackStore.append(rebuilt[k].cells)
            scrollbackWrapped.append(rebuilt[k].wrapped)
        }
        scrollbackStart = 0
        scrollbackCount = keep
        scrolledRows = gridStart

        var newCells = [Cell](repeating: blank, count: newCols * newRows)
        var newWrapped = [Bool](repeating: false, count: newRows)
        for r in 0..<newRows {
            let k = gridStart + r
            guard k < total else { break }
            let row = rebuilt[k].cells
            let copy = min(newCols, row.count)
            for c in 0..<copy { newCells[r * newCols + c] = row[c] }
            // A band painted to the old edge continues to the new one. The
            // row's last cell says which: no glyph but a look of its own is
            // erase-to-end-of-line fill, not a character typed at the margin.
            if copy < newCols, let last = row.last,
               last.scalar == blank.scalar, last.width == blank.width,
               last.bg != blank.bg || last.attrs != blank.attrs {
                var fill = Cell(fg: last.fg, bg: last.bg)
                fill.attrs = last.attrs
                for c in copy..<newCols { newCells[r * newCols + c] = fill }
            }
            newWrapped[r] = rebuilt[k].wrapped
        }

        // 6. Prompt markers ride their logical line to its new first row.
        var seen = Set<Int>()
        prompts = prompts.compactMap { prompt -> Prompt? in
            guard let li = absoluteToLogical[prompt.absoluteLine] else { return nil }
            let moved = logicalFirstRow[li]
            guard moved >= dropped, seen.insert(moved).inserted else { return nil }
            return Prompt(absoluteLine: moved, exitCode: prompt.exitCode)
        }

        return (newCells, newWrapped,
                max(0, min(newCols - 1, newCursorCol)),
                max(0, min(newRows - 1, newCursorRowIndex - gridStart)))
    }

    /// Length of `row` ignoring the run of untouched blanks at its end. A cell
    /// carrying a background color or an attribute is not blank — counting it
    /// out would lose the paint — so only wholly default cells are trimmed.
    /// Columns a row occupies for wrapping. Trailing cells with no glyph are
    /// padding whatever colour they carry: an app that sets a background and
    /// erases to the end of the line has painted a band that ends at the
    /// edge, not written `cols` characters. Counting those cells as content
    /// made every band wrap on a narrowing — a full row plus a stub for the
    /// overhang — and a window drag, which narrows one column at a time,
    /// grew a stub per step and pushed a row of text into history for each.
    /// The same goes for inverse or underlined blanks: a status bar drawn as a
    /// run of inverse spaces is a band to the edge, and would stub the same way.
    private static func trimmedCount(_ row: [Cell], blank: Cell) -> Int {
        var end = row.count
        while end > 0 {
            let c = row[end - 1]
            guard c.scalar == blank.scalar, c.width == blank.width else { break }
            end -= 1
        }
        return end
    }

    /// Columns a row occupies on screen, colour included — the measure for
    /// deciding whether a row is worth keeping at all. A band with no text
    /// is still something the user sees.
    private static func paintedCount(_ row: [Cell], blank: Cell) -> Int {
        var end = row.count
        while end > 0 {
            let c = row[end - 1]
            guard c.scalar == blank.scalar, c.width == blank.width,
                  c.attrs == blank.attrs, c.fg == blank.fg, c.bg == blank.bg else { break }
            end -= 1
        }
        return end
    }

    private static func trimmingTrailingBlanks(_ row: [Cell], blank: Cell) -> [Cell] {
        Array(row[0 ..< trimmedCount(row, blank: blank)])
    }

    private static func resizedGrid(_ src: [Cell],
                                    oldCols: Int, oldRows: Int,
                                    newCols: Int, newRows: Int,
                                    blank: Cell) -> [Cell] {
        var dst = Array(repeating: blank, count: newCols * newRows)
        let copyCols = min(oldCols, newCols)
        let copyRows = min(oldRows, newRows)
        for r in 0..<copyRows {
            for c in 0..<copyCols {
                dst[r * newCols + c] = src[r * oldCols + c]
            }
        }
        return dst
    }
}

enum AnsiPalette {
    /// 256-color resolver. Colors 0-15 come from the theme's ANSI palette;
    /// 16-231 are the xterm 6×6×6 cube; 232-255 are the grayscale ramp.
    static func indexed256(_ idx: Int, palette: [SIMD4<Float>]) -> SIMD4<Float> {
        if idx < 0 || idx > 255 { return palette[7] }
        if idx < 16 { return palette[idx] }
        if idx < 232 {
            let n = idx - 16
            let rIdx = n / 36
            let gIdx = (n / 6) % 6
            let bIdx = n % 6
            func ch(_ v: Int) -> Float {
                v == 0 ? 0 : Float(40 * v + 55) / 255.0
            }
            return SIMD4<Float>(ch(rIdx), ch(gIdx), ch(bIdx), 1)
        }
        let v = (Float(idx - 232) * 10.0 + 8.0) / 255.0
        return SIMD4<Float>(v, v, v, 1)
    }
}
