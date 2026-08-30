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

    init(scalar: Unicode.Scalar = " ",
         fg: PackedColor? = nil,
         bg: PackedColor? = nil,
         attrs: CellAttrs = [],
         width: UInt8 = 1) {
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
    // Theme-derived helpers — read at the call site so future writes always
    // use the current theme. Existing cells keep their previously-baked RGB.
    static var defaultFg: PackedColor { PackedColor(ThemeStore.currentTheme.foreground) }
    static var defaultBg: PackedColor { PackedColor(ThemeStore.currentTheme.background) }

    private(set) var cols: Int
    private(set) var rows: Int
    private var cells: [Cell]
    /// Physical row of logical row 0. Scrolling the whole grid rotates this
    /// instead of moving every cell, which is what makes a line of output
    /// O(cols) rather than O(rows × cols). Kept in [0, rows).
    private var rowOffset = 0

    // Scrollback only retains rows evicted from the PRIMARY screen. Alt-screen
    // scrolls (vim, etc.) are discarded — that matches xterm/iTerm behavior.
    /// Scrollback as a ring. Storage grows to `maxScrollback` rows and then
    /// stops: the oldest row's buffer is recycled to carry the newest, so a
    /// scrolled line costs no allocation in the steady state, and evicting is
    /// an index bump rather than shifting every surviving row down by one.
    /// Rows keep whatever width they had when they were pushed — resize does
    /// not reflow history — so this can't be one flat buffer.
    private var scrollbackStore: [[Cell]] = []
    private var scrollbackStart = 0      // ring slot holding the oldest row
    private var scrollbackCount = 0
    private let maxScrollback: Int = 10_000

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

    // Alt-screen support. When usingAlt is true, `cells` is the alt buffer
    // and `stashed*` holds the primary state.
    private var usingAlt: Bool = false
    private var stashedCells: [Cell] = []
    private var stashedCursor: (col: Int, row: Int) = (0, 0)
    private var stashedFg: PackedColor
    private var stashedBg: PackedColor
    private var stashedAttrs: CellAttrs = []

    init(cols: Int, rows: Int) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        self.scrollBottom = self.rows - 1
        let theme = ThemeStore.currentTheme
        self.currentFg = PackedColor(theme.foreground)
        self.currentBg = PackedColor(theme.background)
        self.savedFg = PackedColor(theme.foreground)
        self.savedBg = PackedColor(theme.background)
        self.stashedFg = PackedColor(theme.foreground)
        self.stashedBg = PackedColor(theme.background)
        self.cells = Array(repeating: Cell(), count: self.cols * self.rows)
        self.tabStops = Self.defaultTabStops(cols: self.cols)
    }

    func resize(cols requestedCols: Int, rows requestedRows: Int) {
        let newCols = max(1, requestedCols)
        let newRows = max(1, requestedRows)
        if newCols == cols && newRows == rows { return }

        // resizedGrid reads the buffer in logical row order.
        normalizeRowOffset()
        cells = Self.resizedGrid(cells, oldCols: cols, oldRows: rows,
                                 newCols: newCols, newRows: newRows)
        if !stashedCells.isEmpty {
            stashedCells = Self.resizedGrid(stashedCells, oldCols: cols, oldRows: rows,
                                            newCols: newCols, newRows: newRows)
        }
        cols = newCols
        rows = newRows
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
        var rebuilt = [Cell](repeating: Cell(), count: cells.count)
        rebuilt.withUnsafeMutableBufferPointer { dst in
            cells.withUnsafeBufferPointer { src in
                for r in 0..<rows {
                    memcpy(dst.baseAddress! + r * cols,
                           src.baseAddress! + rowBase(r),
                           cols * MemoryLayout<Cell>.stride)
                }
            }
        }
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
                cursorCol: cursorCol, cursorRow: cursorRow,
                cursorVisible: cursorVisible,
                scrollbackLines: scrollbackCount,
                scrollOffset: 0,
                title: title,
                prompts: visiblePrompts(offset: 0),
                scrolledRows: scrolledRows,
                currentDirectory: currentDirectory,
                usingAlt: usingAlt
            )
        }

        var viewport = [Cell]()
        viewport.reserveCapacity(cols * rows)

        // Scrollback rows: the offset most-recent rows are pushed UP off-screen,
        // so the rows we want are scrollback[count-offset ..< count] at the top
        // of the viewport.
        let firstScrollbackIdx = scrollbackCount - offset
        let scrollbackRowsShown = min(offset, rows)
        // Scrollback rows can be shorter than the current width; pad with one
        // blank rather than constructing a themed Cell per missing column.
        let padding = Cell()
        for i in 0..<scrollbackRowsShown {
            let row = scrollbackRow(firstScrollbackIdx + i)
            for c in 0..<cols {
                viewport.append(c < row.count ? row[c] : padding)
            }
        }

        // Grid rows: fill the rest of the viewport from the top of the active grid.
        let gridRowsShown = rows - scrollbackRowsShown
        for r in 0..<gridRowsShown {
            for c in 0..<cols {
                viewport.append(cells[rowBase(r) + c])
            }
        }

        // Cursor: only show when scrolled to the bottom; otherwise hide.
        return TerminalSnapshot(
            cols: cols, rows: rows,
            cells: viewport,
            rowOffset: 0,          // composed in logical order already
            cursorCol: cursorCol, cursorRow: cursorRow,
            cursorVisible: false,
            scrollbackLines: scrollbackCount,
            scrollOffset: offset,
            title: title,
            prompts: visiblePrompts(offset: offset),
            scrolledRows: scrolledRows,
            currentDirectory: currentDirectory,
            usingAlt: usingAlt
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
            cells[rowBase(cursorRow) + cursorCol] = Cell()
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
            width: UInt8(width)
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
            if col > 0 { cells[idx - 1] = Cell() }
        case 2:                                     // leading half: tail is right
            if col + 1 < cols { cells[idx + 1] = Cell() }
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
        let theme = ThemeStore.currentTheme
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
                let color = AnsiPalette.indexed256(idx, palette: ThemeStore.currentTheme.ansi)
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
    func applyThemeChange(from old: Theme, to new: Theme) {
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
    }

    private func restoreCursor() {
        cursorCol = min(savedCursor.col, cols - 1)
        cursorRow = min(savedCursor.row, rows - 1)
        currentFg = savedFg
        currentBg = savedBg
        currentAttrs = savedAttrs
    }

    // MARK: alt screen

    private func enterAltScreen(clear: Bool) {
        if usingAlt { return }
        // Stash the primary grid in logical order. A ring offset kept beside
        // it would have to survive a resize, which reflows stashedCells and
        // would leave the offset describing the old geometry.
        normalizeRowOffset()
        stashedCells = cells
        stashedCursor = (cursorCol, cursorRow)
        stashedFg = currentFg
        stashedBg = currentBg
        stashedAttrs = currentAttrs
        cells = Array(repeating: Cell(), count: cols * rows)
        rowOffset = 0
        cursorCol = 0
        cursorRow = 0
        let theme = ThemeStore.currentTheme
        currentFg = PackedColor(theme.foreground)
        currentBg = PackedColor(theme.background)
        currentAttrs = []
        scrollTop = 0
        scrollBottom = rows - 1
        usingAlt = true
    }

    private func exitAltScreen() {
        if !usingAlt { return }
        cells = stashedCells
        rowOffset = 0          // stashed already normalized, see enterAltScreen
        stashedCells = []
        cursorCol = min(stashedCursor.col, cols - 1)
        cursorRow = min(stashedCursor.row, rows - 1)
        currentFg = stashedFg
        currentBg = stashedBg
        currentAttrs = stashedAttrs
        scrollTop = 0
        scrollBottom = rows - 1
        usingAlt = false
    }

    private func fullReset() {
        cells = Array(repeating: Cell(), count: cols * rows)
        rowOffset = 0
        cursorCol = 0
        cursorRow = 0
        let theme = ThemeStore.currentTheme
        currentFg = PackedColor(theme.foreground)
        currentBg = PackedColor(theme.background)
        currentAttrs = []
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
    /// than per cell. `Cell()` consults the theme — a lock plus a Theme copy,
    /// see Cell.init — so a per-column `Cell()` made a full-screen erase cost
    /// one lock acquisition per cell.
    private func blankCells(from index: Int, count: Int) {
        guard count > 0 else { return }
        let blankCell = Cell()
        cells.withUnsafeMutableBufferPointer { buf in
            (buf.baseAddress! + index).update(repeating: blankCell, count: count)
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

        if toScrollback && !usingAlt && top == 0 && bottom == rows - 1 {
            pushToScrollback(lines)
        }
        if top == 0 && bottom == rows - 1 {
            // Whole-grid scroll: the ordinary case, and the only shape the ring
            // can express. Every row moves at once by rotating the offset, so a
            // line of output costs one blanked row instead of a copy of the
            // entire grid.
            rowOffset += lines
            if rowOffset >= rows { rowOffset -= rows }
            for r in (rows - lines)..<rows { blankCells(from: rowBase(r), count: cols) }
            return
        }
        // A margin-bounded region can't rotate — that would drag the rows
        // outside the margins along with it — so those move a row at a time.
        // Rows are no longer adjacent in ring order, hence the per-row move.
        let shiftEnd = bottom - lines
        if shiftEnd >= top {
            for r in top...shiftEnd {
                moveCells(from: rowBase(r + lines), to: rowBase(r), count: cols)
            }
        }
        for r in (bottom - lines + 1)...bottom { blankCells(from: rowBase(r), count: cols) }
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
            for r in 0..<lines { blankCells(from: rowBase(r), count: cols) }
            return
        }
        let shiftStart = top + lines
        if shiftStart <= bottom {
            // Descending, so a row is never overwritten before it is read.
            for r in stride(from: bottom, through: shiftStart, by: -1) {
                moveCells(from: rowBase(r - lines), to: rowBase(r), count: cols)
            }
        }
        for r in top...(top + lines - 1) { blankCells(from: rowBase(r), count: cols) }
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
                for r in (cursorRow + 1)..<rows { blankCells(from: rowBase(r), count: cols) }
            }
        case 1:
            for r in 0..<cursorRow { blankCells(from: rowBase(r), count: cols) }
            blankCells(from: rowBase(cursorRow), count: min(cursorCol, cols - 1) + 1)
        case 2, 3:
            // Every row is cleared, so ring order doesn't matter here.
            blankCells(from: 0, count: cells.count)
        default:
            break
        }
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
        case 1:
            blankCells(from: rowBase(cursorRow), count: min(cursorCol, cols - 1) + 1)
        case 2:
            blankCells(from: rowBase(cursorRow), count: cols)
        default:
            break
        }
    }

    // MARK: SGR

    private func applySGR(_ params: [Int]) {
        let theme = ThemeStore.currentTheme
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

    private static func resizedGrid(_ src: [Cell],
                                    oldCols: Int, oldRows: Int,
                                    newCols: Int, newRows: Int) -> [Cell] {
        var dst = Array(repeating: Cell(), count: newCols * newRows)
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
