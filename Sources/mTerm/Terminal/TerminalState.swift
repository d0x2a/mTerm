import Foundation
import simd

struct CellAttrs: OptionSet {
    let rawValue: UInt8
    static let bold      = CellAttrs(rawValue: 1 << 0)
    static let italic    = CellAttrs(rawValue: 1 << 1)
    static let underline = CellAttrs(rawValue: 1 << 2)
    static let inverse   = CellAttrs(rawValue: 1 << 3)
}

struct Cell {
    var scalar: Unicode.Scalar
    var fg: SIMD4<Float>
    var bg: SIMD4<Float>
    var attrs: CellAttrs

    init(scalar: Unicode.Scalar = " ",
         fg: SIMD4<Float>? = nil,
         bg: SIMD4<Float>? = nil,
         attrs: CellAttrs = []) {
        let theme = ThemeStore.currentTheme
        self.scalar = scalar
        self.fg = fg ?? theme.foreground
        self.bg = bg ?? theme.background
        self.attrs = attrs
    }

    var isBlank: Bool { scalar == " " && attrs.isEmpty }
}

struct TerminalSnapshot {
    let cols: Int
    let rows: Int
    let cells: [Cell]
    let cursorCol: Int
    let cursorRow: Int
    let cursorVisible: Bool
    let scrollbackLines: Int       // total lines available in scrollback
    let scrollOffset: Int          // how many of those are showing above the grid
    let title: String              // last OSC 0/2 title from the shell
    let prompts: [PromptMark]      // prompt markers currently visible in the viewport
    let scrolledRows: Int          // total lines ever pushed to scrollback (for absolute coords)
    let currentDirectory: String?  // last OSC 7 reported cwd
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

    /// Extracts the selected text from a snapshot, joining rows with "\n" and
    /// trimming trailing whitespace per row.
    func extractText(from snapshot: TerminalSnapshot) -> String {
        guard startRow >= 0, endRow < snapshot.rows else { return "" }
        var lines: [String] = []
        for r in startRow...endRow {
            let firstCol = (r == startRow) ? startCol : 0
            let lastCol  = (r == endRow)   ? endCol   : snapshot.cols - 1
            var line = ""
            for c in firstCol...lastCol {
                line.unicodeScalars.append(snapshot.cells[r * snapshot.cols + c].scalar)
            }
            // Strip trailing spaces from each row except the last (so single-line
            // selections preserve trailing spaces if you actually selected them).
            if r != endRow {
                while line.last == " " { line.removeLast() }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

final class TerminalState: ParserSink {
    // Theme-derived helpers — read at the call site so future writes always
    // use the current theme. Existing cells keep their previously-baked RGB.
    static var defaultFg: SIMD4<Float> { ThemeStore.currentTheme.foreground }
    static var defaultBg: SIMD4<Float> { ThemeStore.currentTheme.background }

    private(set) var cols: Int
    private(set) var rows: Int
    private var cells: [Cell]

    // Scrollback only retains rows evicted from the PRIMARY screen. Alt-screen
    // scrolls (vim, etc.) are discarded — that matches xterm/iTerm behavior.
    private var scrollback: [[Cell]] = []
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

    private(set) var cursorCol: Int = 0
    private(set) var cursorRow: Int = 0
    private(set) var cursorVisible: Bool = true
    private(set) var title: String = ""
    private(set) var currentDirectory: String? = nil

    private var currentFg: SIMD4<Float>
    private var currentBg: SIMD4<Float>
    private var currentAttrs: CellAttrs = []

    // DECSC / DECRC slot (separate from alt-screen stash).
    private var savedCursor: (col: Int, row: Int) = (0, 0)
    private var savedFg: SIMD4<Float>
    private var savedBg: SIMD4<Float>
    private var savedAttrs: CellAttrs = []

    // Alt-screen support. When usingAlt is true, `cells` is the alt buffer
    // and `stashed*` holds the primary state.
    private var usingAlt: Bool = false
    private var stashedCells: [Cell] = []
    private var stashedCursor: (col: Int, row: Int) = (0, 0)
    private var stashedFg: SIMD4<Float>
    private var stashedBg: SIMD4<Float>
    private var stashedAttrs: CellAttrs = []

    init(cols: Int, rows: Int) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        let theme = ThemeStore.currentTheme
        self.currentFg = theme.foreground
        self.currentBg = theme.background
        self.savedFg = theme.foreground
        self.savedBg = theme.background
        self.stashedFg = theme.foreground
        self.stashedBg = theme.background
        self.cells = Array(repeating: Cell(), count: self.cols * self.rows)
    }

    func resize(cols requestedCols: Int, rows requestedRows: Int) {
        let newCols = max(1, requestedCols)
        let newRows = max(1, requestedRows)
        if newCols == cols && newRows == rows { return }

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
    }

    func snapshot() -> TerminalSnapshot {
        viewportSnapshot(scrollOffset: 0)
    }

    /// Composes a `rows`-tall viewport. With scrollOffset=0 the viewport is the
    /// active grid. With scrollOffset>0 the top N rows come from scrollback.
    func viewportSnapshot(scrollOffset requested: Int) -> TerminalSnapshot {
        let offset = max(0, min(requested, scrollback.count))
        if offset == 0 {
            return TerminalSnapshot(
                cols: cols, rows: rows,
                cells: cells,
                cursorCol: cursorCol, cursorRow: cursorRow,
                cursorVisible: cursorVisible,
                scrollbackLines: scrollback.count,
                scrollOffset: 0,
                title: title,
                prompts: visiblePrompts(offset: 0),
                scrolledRows: scrolledRows,
                currentDirectory: currentDirectory
            )
        }

        var viewport = [Cell]()
        viewport.reserveCapacity(cols * rows)

        // Scrollback rows: the offset most-recent rows are pushed UP off-screen,
        // so the rows we want are scrollback[count-offset ..< count] at the top
        // of the viewport.
        let firstScrollbackIdx = scrollback.count - offset
        let scrollbackRowsShown = min(offset, rows)
        for i in 0..<scrollbackRowsShown {
            let row = scrollback[firstScrollbackIdx + i]
            for c in 0..<cols {
                viewport.append(c < row.count ? row[c] : Cell())
            }
        }

        // Grid rows: fill the rest of the viewport from the top of the active grid.
        let gridRowsShown = rows - scrollbackRowsShown
        for r in 0..<gridRowsShown {
            for c in 0..<cols {
                viewport.append(cells[r * cols + c])
            }
        }

        // Cursor: only show when scrolled to the bottom; otherwise hide.
        return TerminalSnapshot(
            cols: cols, rows: rows,
            cells: viewport,
            cursorCol: cursorCol, cursorRow: cursorRow,
            cursorVisible: false,
            scrollbackLines: scrollback.count,
            scrollOffset: offset,
            title: title,
            prompts: visiblePrompts(offset: offset),
            scrolledRows: scrolledRows,
            currentDirectory: currentDirectory
        )
    }

    // MARK: ParserSink

    func parserPrint(_ scalar: Unicode.Scalar) {
        if cursorCol >= cols {
            cursorCol = 0
            advanceRow()
        }
        let idx = cursorRow * cols + cursorCol
        let inv = currentAttrs.contains(.inverse)
        cells[idx] = Cell(
            scalar: scalar,
            fg: inv ? currentBg : currentFg,
            bg: inv ? currentFg : currentBg,
            attrs: currentAttrs
        )
        cursorCol += 1
    }

    func parserExecute(_ control: UInt8) {
        switch control {
        case 0x07: break                            // BEL
        case 0x08:                                  // BS
            if cursorCol > 0 { cursorCol -= 1 }
        case 0x09:                                  // HT — next 8-col tab stop
            let next = ((cursorCol / 8) + 1) * 8
            cursorCol = min(cols - 1, next)
        case 0x0A, 0x0B, 0x0C:                      // LF/VT/FF
            advanceRow()
        case 0x0D:                                  // CR
            cursorCol = 0
        default:
            break
        }
    }

    func parserCSI(_ params: [Int], isPrivate: Bool, intermediates: [UInt8], final: UInt8) {
        if !intermediates.isEmpty { return }
        if isPrivate {
            handlePrivateCSI(params: params, final: final)
            return
        }
        let p0 = params.first ?? 0
        switch final {
        case 0x41:                                  // 'A' CUU
            cursorRow = max(0, cursorRow - max(1, p0))
        case 0x42:                                  // 'B' CUD
            cursorRow = min(rows - 1, cursorRow + max(1, p0))
        case 0x43:                                  // 'C' CUF
            cursorCol = min(cols - 1, cursorCol + max(1, p0))
        case 0x44:                                  // 'D' CUB
            cursorCol = max(0, cursorCol - max(1, p0))
        case 0x47:                                  // 'G' CHA
            cursorCol = max(0, min(cols - 1, max(1, p0) - 1))
        case 0x48, 0x66:                            // 'H' / 'f' CUP
            let r = params.count >= 1 ? max(1, params[0]) : 1
            let c = params.count >= 2 ? max(1, params[1]) : 1
            cursorRow = min(rows - 1, r - 1)
            cursorCol = min(cols - 1, c - 1)
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

    func parserOSC(_ data: [UInt8]) {
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
        case 133:
            handlePrompt133(payload)
        default:
            break
        }
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
        var colorMap: [SIMD4<Float>: SIMD4<Float>] = [:]
        for i in 0..<min(old.ansi.count, new.ansi.count) {
            colorMap[old.ansi[i]] = new.ansi[i]
        }
        colorMap[old.foreground] = new.foreground
        colorMap[old.background] = new.background

        for i in 0..<cells.count {
            if let nfg = colorMap[cells[i].fg] { cells[i].fg = nfg }
            if let nbg = colorMap[cells[i].bg] { cells[i].bg = nbg }
        }
        for r in 0..<scrollback.count {
            for c in 0..<scrollback[r].count {
                if let nfg = colorMap[scrollback[r][c].fg] { scrollback[r][c].fg = nfg }
                if let nbg = colorMap[scrollback[r][c].bg] { scrollback[r][c].bg = nbg }
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
        let topOfHistory = scrolledRows - scrollback.count
        for (i, row) in scrollback.enumerated() {
            scanRow(row, absLine: topOfHistory + i,
                    query: query, pattern: pattern,
                    caseSensitive: caseSensitive, into: &matches)
        }
        for r in 0..<rows {
            let row = Array(cells[r * cols ..< (r + 1) * cols])
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
        // Build a String where each cell scalar maps to exactly one UTF-16
        // code unit. Since our parser only stores BMP scalars (>0xFFFF are
        // skipped), this means string offsets == cell columns.
        var line = ""
        line.reserveCapacity(row.count)
        for cell in row {
            if cell.scalar.value <= 0xFFFF {
                line.unicodeScalars.append(cell.scalar)
            } else {
                line.unicodeScalars.append(" ")
            }
        }
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)

        if let pattern = pattern {
            for m in pattern.matches(in: line, range: full) {
                if m.range.location == NSNotFound || m.range.length == 0 { continue }
                matches.append(SearchMatch(absoluteLine: absLine,
                                           startCol: m.range.location,
                                           endCol: m.range.location + m.range.length))
            }
        } else {
            let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            var pos = 0
            while pos < ns.length {
                let searchRange = NSRange(location: pos, length: ns.length - pos)
                let r = ns.range(of: query, options: options, range: searchRange)
                if r.location == NSNotFound || r.length == 0 { break }
                matches.append(SearchMatch(absoluteLine: absLine,
                                           startCol: r.location,
                                           endCol: r.location + r.length))
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
        if !intermediates.isEmpty { return }
        switch final {
        case 0x37:                                  // '7' DECSC
            saveCursor()
        case 0x38:                                  // '8' DECRC
            restoreCursor()
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
            case 25:
                cursorVisible = set
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
        stashedCells = cells
        stashedCursor = (cursorCol, cursorRow)
        stashedFg = currentFg
        stashedBg = currentBg
        stashedAttrs = currentAttrs
        cells = Array(repeating: Cell(), count: cols * rows)
        cursorCol = 0
        cursorRow = 0
        let theme = ThemeStore.currentTheme
        currentFg = theme.foreground
        currentBg = theme.background
        currentAttrs = []
        usingAlt = true
    }

    private func exitAltScreen() {
        if !usingAlt { return }
        cells = stashedCells
        stashedCells = []
        cursorCol = min(stashedCursor.col, cols - 1)
        cursorRow = min(stashedCursor.row, rows - 1)
        currentFg = stashedFg
        currentBg = stashedBg
        currentAttrs = stashedAttrs
        usingAlt = false
    }

    private func fullReset() {
        cells = Array(repeating: Cell(), count: cols * rows)
        cursorCol = 0
        cursorRow = 0
        let theme = ThemeStore.currentTheme
        currentFg = theme.foreground
        currentBg = theme.background
        currentAttrs = []
        cursorVisible = true
    }

    // MARK: scrolling / erase

    private func advanceRow() {
        if cursorRow >= rows - 1 {
            scrollUp(1)
        } else {
            cursorRow += 1
        }
    }

    private func scrollUp(_ n: Int) {
        let lines = min(n, rows)
        if !usingAlt {
            for r in 0..<lines {
                let row = Array(cells[r * cols ..< (r + 1) * cols])
                scrollback.append(row)
            }
            if scrollback.count > maxScrollback {
                scrollback.removeFirst(scrollback.count - maxScrollback)
            }
            scrolledRows += lines
            // Drop prompts that have fallen out of scrollback.
            let topOfHistory = scrolledRows - scrollback.count
            if let firstKeep = prompts.firstIndex(where: { $0.absoluteLine >= topOfHistory }),
               firstKeep > 0 {
                prompts.removeFirst(firstKeep)
            } else if !prompts.isEmpty,
                      prompts.last!.absoluteLine < topOfHistory {
                prompts.removeAll()
            }
        }
        cells.removeFirst(lines * cols)
        cells.append(contentsOf: Array(repeating: Cell(), count: lines * cols))
    }

    private func eraseDisplay(mode: Int) {
        switch mode {
        case 0:
            eraseLine(mode: 0)
            if cursorRow + 1 < rows {
                for r in (cursorRow + 1)..<rows {
                    for c in 0..<cols { cells[r * cols + c] = Cell() }
                }
            }
        case 1:
            if cursorRow > 0 {
                for r in 0..<cursorRow {
                    for c in 0..<cols { cells[r * cols + c] = Cell() }
                }
            }
            for c in 0...min(cursorCol, cols - 1) {
                cells[cursorRow * cols + c] = Cell()
            }
        case 2, 3:
            for i in 0..<cells.count { cells[i] = Cell() }
        default:
            break
        }
    }

    private func eraseLine(mode: Int) {
        switch mode {
        case 0:
            for c in cursorCol..<cols { cells[cursorRow * cols + c] = Cell() }
        case 1:
            for c in 0...min(cursorCol, cols - 1) { cells[cursorRow * cols + c] = Cell() }
        case 2:
            for c in 0..<cols { cells[cursorRow * cols + c] = Cell() }
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
                currentFg = theme.foreground
                currentBg = theme.background
                currentAttrs = []
            case 1:  currentAttrs.insert(.bold)
            case 3:  currentAttrs.insert(.italic)
            case 4:  currentAttrs.insert(.underline)
            case 7:  currentAttrs.insert(.inverse)
            case 22: currentAttrs.remove(.bold)
            case 23: currentAttrs.remove(.italic)
            case 24: currentAttrs.remove(.underline)
            case 27: currentAttrs.remove(.inverse)
            case 30...37:
                currentFg = palette[p - 30]
            case 38:
                if let color = readExtendedColor(params, index: &i, palette: palette) { currentFg = color }
            case 39:
                currentFg = theme.foreground
            case 40...47:
                currentBg = palette[p - 40]
            case 48:
                if let color = readExtendedColor(params, index: &i, palette: palette) { currentBg = color }
            case 49:
                currentBg = theme.background
            case 90...97:
                currentFg = palette[p - 90 + 8]
            case 100...107:
                currentBg = palette[p - 100 + 8]
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
