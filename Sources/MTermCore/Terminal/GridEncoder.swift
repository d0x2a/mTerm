import Foundation

extension TerminalState {
    /// The screen as the bytes that would draw it. See `GridEncoder`.
    package func encodeScreen() -> [UInt8] {
        GridEncoder.encode(screenCapture())
    }

    /// The theme `encodeScreen`'s default colours are in — this buffer's own,
    /// which a theme remap changes. A computed accessor rather than widening
    /// the stored property: package-visible storage on this class costs the
    /// parser its exclusivity-check elimination.
    package var screenTheme: Theme { theme }
}

/// What `GridEncoder` works from: a `TerminalState`'s screen and everything
/// that decides how later output lands on it, copied out in logical row order.
struct ScreenCapture {
    struct Pen: Equatable {
        var fg: PackedColor
        var bg: PackedColor
        var attrs: CellAttrs
        /// The open hyperlink's target, not its id: ids are per buffer.
        var link: String?
    }

    let cols: Int
    let rows: Int
    let defaultFg: PackedColor
    let defaultBg: PackedColor
    /// The primary screen, which is behind the alt screen when that is up.
    let primary: [Cell]
    let primaryWrapped: [Bool]
    let alt: (cells: [Cell], wrapped: [Bool])?
    /// Where leaving the alt screen puts the cursor and pen back. The same
    /// as `cursor` and `pen` while the alt screen is down.
    let primaryCursor: (col: Int, row: Int)
    let primaryPen: Pen
    let cursor: (col: Int, row: Int)
    let cursorVisible: Bool
    let pen: Pen
    /// The DECSC slot.
    let savedCursor: (col: Int, row: Int)
    let savedPen: Pen
    /// Targets behind `Cell.link`, which is 1-based.
    let links: [String]
    let charsets: [UInt8]
    let activeCharset: Int
    let tabStops: Set<Int>
    let defaultTabStops: Set<Int>
    let title: String
    let currentDirectory: String?
    let autoWrap: Bool
    let originMode: Bool
    let mouseTracking: MouseTracking
    let mouseEncoding: MouseEncoding
    let reportFocus: Bool
    let bracketedPaste: Bool
    let alternateScroll: Bool
    let scrollTop: Int
    let scrollBottom: Int
    let prompts: [PromptMark]
}

/// A `TerminalState`'s screen, as the bytes that would draw it.
///
/// Parsed into a fresh `TerminalState` of the same size and theme, the output
/// leaves it indistinguishable from the original: every cell on the screen —
/// and on the primary screen behind the alt screen, when that is up — with its
/// colours, attributes, width and hyperlink, the wrap flags, the cursor, the
/// pen and an open hyperlink, the DECSC slot, the modes, margins, tab stops,
/// character sets, title, directory and prompt marks. Output that follows then
/// lands on the copy exactly as it lands on the original, which is what a
/// second head needs from the moment it attaches.
///
/// Not carried: scrollback, which is history rather than the screen and is
/// better paged on request; the glyph a `REP` would repeat; and an open DEC
/// 2026 update — the capture brackets itself in one.
///
/// Everything is drawn through the ordinary parser, so the copy's grid is
/// built by the same code the original's was. That is also what makes the
/// awkward parts awkward: there is no sequence that sets a wrap flag or places
/// half of a wide glyph, so those are produced the way a program would produce
/// them, and then the scaffolding is drawn over.
enum GridEncoder {
    static func encode(_ capture: ScreenCapture) -> [UInt8] {
        var writer = Writer(capture)
        writer.run()
        return writer.out
    }
}

private struct Writer {
    let c: ScreenCapture
    var out: [UInt8] = []
    /// The copy's pen and link as the bytes so far have left them.
    var pen: ScreenCapture.Pen
    /// Whether CUP is counted from the top margin yet. Only at the very end.
    var origin = false

    init(_ capture: ScreenCapture) {
        c = capture
        pen = ScreenCapture.Pen(fg: capture.defaultFg, bg: capture.defaultBg, attrs: [], link: nil)
        out.reserveCapacity(capture.cols * capture.rows * 2 + 256)
    }

    mutating func run() {
        emit("\u{1B}[?2026h")

        draw(c.primary, wrapped: c.primaryWrapped, prompts: c.prompts)
        if let alt = c.alt {
            // What leaving the alt screen will put back, then into it. ?1047
            // rather than ?1049, which would also overwrite the DECSC slot.
            moveTo(min(c.primaryCursor.col, c.cols - 1), c.primaryCursor.row)
            setPen(c.primaryPen)
            emit("\u{1B}[?1047h")
            // Entering resets the pen and closes the link.
            pen = ScreenCapture.Pen(fg: c.defaultFg, bg: c.defaultBg, attrs: [], link: nil)
            draw(alt.cells, wrapped: alt.wrapped, prompts: [])
        }

        // The DECSC slot. Restoring clamps to the last column, so a cursor
        // saved just past it can be saved on it instead.
        moveTo(min(c.savedCursor.col, c.cols - 1), c.savedCursor.row)
        setPen(c.savedPen)
        emit("\u{1B}7")

        if c.tabStops != c.defaultTabStops {
            emit("\u{1B}[3g")
            for stop in c.tabStops.sorted() {
                moveTo(stop, 0)
                emit("\u{1B}H")
            }
        }

        if !c.title.isEmpty { emit("\u{1B}]2;\(c.title)\u{07}") }
        if let dir = c.currentDirectory {
            emit("\u{1B}]7;\(URL(fileURLWithPath: dir, isDirectory: false).absoluteString)\u{07}")
        }

        if !c.autoWrap { emit("\u{1B}[?7l") }
        if !c.cursorVisible { emit("\u{1B}[?25l") }
        switch c.mouseTracking {
        case .off: break
        case .x10: emit("\u{1B}[?9h")
        case .normal: emit("\u{1B}[?1000h")
        case .buttonEvent: emit("\u{1B}[?1002h")
        case .anyEvent: emit("\u{1B}[?1003h")
        }
        if c.mouseEncoding == .sgr { emit("\u{1B}[?1006h") }
        if c.reportFocus { emit("\u{1B}[?1004h") }
        if c.bracketedPaste { emit("\u{1B}[?2004h") }
        // After the alt screen, which turns this back on as it is entered.
        if !c.alternateScroll { emit("\u{1B}[?1007l") }

        // Margins and origin mode both home the cursor, so they go before it.
        if c.scrollTop != 0 || c.scrollBottom != c.rows - 1 {
            emit("\u{1B}[\(c.scrollTop + 1);\(c.scrollBottom + 1)r")
        }
        if c.originMode {
            emit("\u{1B}[?6h")
            origin = true
        }
        placeCursor()

        setPen(c.pen)
        // Last, because they change what the ASCII printed above would draw.
        if c.charsets[0] != 0x42 { emit("\u{1B}("); out.append(c.charsets[0]) }
        if c.charsets[1] != 0x42 { emit("\u{1B})"); out.append(c.charsets[1]) }
        if c.activeCharset == 1 { out.append(0x0E) }

        emit("\u{1B}[?2026l")
    }

    // MARK: the grid

    mutating func draw(_ cells: [Cell], wrapped: [Bool], prompts: [PromptMark]) {
        // Wrap flags first, while the rows are empty. Only a glyph arriving
        // past the right edge sets one, and it lands at the start of the next
        // row — which would overwrite what was already drawn there — while
        // nothing that draws the rows afterwards ever clears one.
        for r in 0 ..< c.rows - 1 where wrapped[r] {
            moveTo(c.cols - 1, r)
            emit("xx")
        }
        // The bottom row wraps only from below the margins, where a line
        // feed can't scroll: make it so for a moment.
        if wrapped[c.rows - 1], c.rows >= 3 {
            emit("\u{1B}[1;\(c.rows - 1)r")
            moveTo(c.cols - 1, c.rows - 1)
            emit("xx")
            emit("\u{1B}[r")
        }

        for r in 0 ..< c.rows {
            moveTo(0, r)
            drawRow(Array(cells[r * c.cols ..< (r + 1) * c.cols]), r)
        }

        // Prompt marks in the order they arrived, not row order: an exit code
        // goes to the most recent prompt, and after the cursor has been moved
        // up that need not be the lowest one.
        for mark in prompts {
            moveTo(0, mark.viewportRow)
            emit("\u{1B}]133;A\u{07}")
            if let code = mark.exitCode { emit("\u{1B}]133;D;\(code)\u{07}") }
        }
    }

    /// Draws one row left to right. Most of it is printing; the rest is half
    /// of a wide glyph with the other half gone, which printing can't leave
    /// behind on its own. Those are printed whole and then cut down with the
    /// three sequences that move cells without tidying up after them: ECH,
    /// DCH and ICH.
    mutating func drawRow(_ row: [Cell], _ r: Int) {
        let last = c.cols - 1
        var col = 0
        var end = c.cols

        // A stray right half in column 0 has no column for its left: print
        // the pair at 0 and delete the left half, sliding the right into 0.
        // First, while there is nothing else on the row for that to shift.
        if c.cols >= 2, row[0].width == 0 {
            moveTo(0, r)
            putPlaceholder(penFor(row[0]))
            moveTo(0, r)
            emit("\u{1B}[P")
            col = 1
        }
        // A stray half in the last column, before its left neighbour is drawn
        // over the scaffolding it needs.
        if c.cols >= 2, col <= last - 1 {
            if row[last].width == 0, row[last - 1].width != 2 {
                // Right half: print the pair ending on it, blank the left.
                moveTo(last - 1, r)
                putPlaceholder(penFor(row[last]))
                moveTo(last - 1, r)
                emit("\u{1B}[X")
                end = last
            } else if row[last].width == 2 {
                // Left half with no room for its right: print the pair one
                // column early and push it over, dropping the right half.
                moveTo(last - 1, r)
                put(row[last])
                moveTo(last - 1, r)
                emit("\u{1B}[@")
                end = last
            }
        }

        moveTo(col, r)
        while col < end {
            let cell = row[col]
            if cell.width == 2 {
                if col + 1 < end, row[col + 1].width == 0 {
                    put(cell)                           // an ordinary pair
                    col += 2
                } else {
                    // Left half, right neighbour not its own: print the pair,
                    // then blank the right half it brought with it.
                    put(cell)
                    emit("\u{1B}[D\u{1B}[X")
                    col += 1
                }
            } else if cell.width == 0 {
                // Right half, left neighbour not its own: print a pair ending
                // on it, then redraw whatever the placeholder's left covered.
                let start = col >= 2 && row[col - 1].width == 0 && row[col - 2].width == 2
                    ? col - 2 : col - 1
                moveTo(col - 1, r)
                putPlaceholder(penFor(cell))
                moveTo(start, r)
                emit("\u{1B}[\(col - start)X")
                // A pair, or a single glyph. Another stray half can't be put
                // back beside this one; it stays blank.
                if start == col - 2 || row[start].width == 1 {
                    put(row[start])
                }
                moveTo(col + 1, r)
                col += 1
            } else if isErased(cell) {
                // A run of erased cells goes out as one ECH, not a space each.
                var n = 1
                while col + n < end, sameCell(row[col + n], cell) { n += 1 }
                setPen(ScreenCapture.Pen(fg: pen.fg, bg: cell.bg, attrs: pen.attrs, link: pen.link))
                emit(n == 1 ? "\u{1B}[X" : "\u{1B}[\(n)X")
                col += n
                if col < end { moveTo(col, r) }
            } else {
                put(cell)
                col += 1
            }
        }
    }

    /// The final cursor. One just past the last column, with a wrap pending,
    /// is where printing the row's last glyph leaves it, so print it again.
    mutating func placeCursor() {
        let (col, row) = c.cursor
        guard col >= c.cols else {
            moveTo(col, row)
            return
        }
        let last = c.cols - 1
        let cells = c.alt?.cells ?? c.primary
        let lastCell = cells[row * c.cols + last]
        if lastCell.width == 0, last >= 1, cells[row * c.cols + last - 1].width == 2 {
            moveTo(last - 1, row)
            put(cells[row * c.cols + last - 1])
        } else if lastCell.width == 1 {
            moveTo(last, row)
            put(lastCell)
        } else {
            moveTo(last, row)                           // a stray half can't be reprinted
        }
    }

    // MARK: cells and the pen

    /// Blank as an erase leaves it: what ECH produces from the pen's background.
    func isErased(_ cell: Cell) -> Bool {
        cell.scalar == " " && cell.width == 1 && cell.attrs.isEmpty
            && cell.link == 0 && cell.fg == c.defaultFg
    }

    func sameCell(_ a: Cell, _ b: Cell) -> Bool {
        a.scalar == b.scalar && a.fg == b.fg && a.bg == b.bg && a.attrs == b.attrs
            && a.width == b.width && a.link == b.link
    }

    /// The pen that prints `cell` as it is. An inverse cell holds its colours
    /// already swapped, so the pen has them the other way round.
    func penFor(_ cell: Cell) -> ScreenCapture.Pen {
        let link = cell.link == 0 || Int(cell.link) > c.links.count ? nil : c.links[Int(cell.link) - 1]
        return cell.attrs.contains(.inverse)
            ? ScreenCapture.Pen(fg: cell.bg, bg: cell.fg, attrs: cell.attrs, link: link)
            : ScreenCapture.Pen(fg: cell.fg, bg: cell.bg, attrs: cell.attrs, link: link)
    }

    mutating func put(_ cell: Cell) {
        setPen(penFor(cell))
        out.append(contentsOf: Array(String(cell.scalar).utf8))
    }

    /// A wide glyph in `pen`, printed only for the half it leaves behind.
    mutating func putPlaceholder(_ pen: ScreenCapture.Pen) {
        setPen(pen)
        emit("中")
    }

    mutating func setPen(_ target: ScreenCapture.Pen) {
        if target.fg != pen.fg || target.bg != pen.bg || target.attrs != pen.attrs {
            var sgr = "\u{1B}[0"
            if target.attrs.contains(.bold) { sgr += ";1" }
            if target.attrs.contains(.faint) { sgr += ";2" }
            if target.attrs.contains(.italic) { sgr += ";3" }
            if target.attrs.contains(.underline) { sgr += ";4" }
            if target.attrs.contains(.inverse) { sgr += ";7" }
            if target.fg != c.defaultFg { sgr += ";38;2;" + rgb(target.fg) }
            if target.bg != c.defaultBg { sgr += ";48;2;" + rgb(target.bg) }
            emit(sgr + "m")
        }
        if target.link != pen.link {
            emit("\u{1B}]8;;\(target.link ?? "")\u{07}")
        }
        pen = target
    }

    func rgb(_ color: PackedColor) -> String {
        "\(color.value & 0xFF);\((color.value >> 8) & 0xFF);\((color.value >> 16) & 0xFF)"
    }

    // MARK: bytes

    mutating func moveTo(_ col: Int, _ row: Int) {
        let line = origin ? row - c.scrollTop + 1 : row + 1
        emit("\u{1B}[\(line);\(col + 1)H")
    }

    mutating func emit(_ s: String) {
        out.append(contentsOf: Array(s.utf8))
    }
}
