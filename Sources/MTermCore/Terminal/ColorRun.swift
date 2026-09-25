import Foundation

/// A run of text set in a colour of its own, and what ⌘-click puts on the
/// pasteboard.
package struct ColorRun: Equatable {
    /// One piece of the run on one viewport row. `length` is in cells.
    package struct Segment: Equatable {
        package let row: Int
        package let col: Int
        package let length: Int

        package init(row: Int, col: Int, length: Int) {
            self.row = row
            self.col = col
            self.length = length
        }
    }

    /// Top to bottom, one per row. This is the extent that gets marked, so
    /// what lights up is exactly what gets copied.
    package let segments: [Segment]
    /// The segments rejoined: a row the terminal wrapped continues without a
    /// break, a row the program broke itself continues after a space.
    package let text: String
    /// The run's foreground, for marking it in a colour that is certain to
    /// show against the background — the theme's selection colour isn't:
    /// Pencil Light's is #ededed on #f9f9f9.
    package let color: PackedColor

    package init(segments: [Segment], text: String, color: PackedColor) {
        self.segments = segments
        self.text = text
        self.color = color
    }
}

/// Finds the coloured run under the pointer.
///
/// A TUI that renders markdown sets things apart by colour and nothing else —
/// Claude Code prints inline code and quoted drafts in an accent colour, with
/// no marker in the bytes saying where they begin or end. The colour is the
/// boundary: the run is every neighbouring cell with the same foreground and
/// background as the one clicked. Attributes are ignored, so a bold word
/// inside a coloured sentence doesn't cut it in two.
///
/// Except a space's foreground, which never shows, and Claude Code doesn't
/// set one: its coloured sentences reach the grid as coloured words with
/// default-coloured spaces between them. So a lone space between two cells of
/// the run belongs to it — unless the row is laid out in columns, which `ls`
/// pads with a single space after its longest name. What gives a column
/// layout away is a wider gap elsewhere in the row with the colour on both
/// sides; prose, coloured or not, doesn't have one.
///
/// Such a TUI also does its own word wrap, so a coloured paragraph reaches the
/// grid as separate rows with no wrap flag between them. A run carries on to
/// the next row when it is the last thing on its row, the next row opens in
/// the same colour, and that row's first word would not have fitted where
/// this one ended — which is why the program broke the line there. The fit
/// test is what keeps `ls -1` from fusing a column of blue directory names
/// into one: short lines that stop far from the edge weren't wrapped.
package enum ColorRunDetector {
    /// How far short of the right edge a program's own wrap column may sit.
    /// A TUI wraps inside its own margins, not at the terminal's width.
    package static let wrapSlack = 8

    /// Past this many rows it is a screen of coloured output rather than a
    /// passage someone set apart, and marking it would light up the window.
    package static let maxRows = 40

    /// The run under `coord`, or nil when the cell there is in the default
    /// foreground, or is padding beside a run rather than part of it.
    package static func run(at coord: (col: Int, row: Int),
                            snapshot: TerminalSnapshot,
                            defaultForeground: PackedColor) -> ColorRun? {
        let cols = snapshot.cols
        guard coord.row >= 0, coord.row < snapshot.rows,
              coord.col >= 0, coord.col < cols else { return nil }
        let grid = Grid(snapshot: snapshot)

        // On the space between two words of a run, start from the word to
        // its left, so the mark doesn't blink off as the pointer crosses it.
        var hit = grid.lead(coord.row, coord.col)
        if let left = grid.bridgedGap(at: hit, row: coord.row) { hit = left }
        let key = grid.key(coord.row, hit)
        guard key.fg != defaultForeground else { return nil }

        guard let first = grid.segment(through: hit, row: coord.row, key: key),
              first.lo <= coord.col, coord.col <= first.hi,
              grid.hasWord(first) else { return nil }
        var spans = [first]

        // Down, while the run is what ends its row and the next row opens in
        // its colour.
        while let last = spans.last, last.row + 1 < snapshot.rows,
              last.hi == grid.contentEnd(last.row),
              let start = grid.contentStart(last.row + 1),
              grid.key(last.row + 1, start) == key,
              grid.runsOn(from: last.row, end: last.hi, to: last.row + 1, start: start),
              let next = grid.segment(through: start, row: last.row + 1, key: key),
              next.lo == start, grid.hasWord(next) {
            spans.append(next)
            guard spans.count <= maxRows else { return nil }
        }

        // Up, while the run is what opens its row and the row above ends in
        // its colour.
        while let top = spans.first, top.row > 0,
              top.lo == grid.contentStart(top.row),
              let end = grid.contentEnd(top.row - 1),
              grid.key(top.row - 1, grid.lead(top.row - 1, end)) == key,
              grid.runsOn(from: top.row - 1, end: end, to: top.row, start: top.lo),
              let prev = grid.segment(through: grid.lead(top.row - 1, end), row: top.row - 1, key: key),
              prev.hi == end, grid.hasWord(prev) {
            spans.insert(prev, at: 0)
            guard spans.count <= maxRows else { return nil }
        }

        var text = ""
        for (i, span) in spans.enumerated() {
            if i > 0 {
                let above = spans[i - 1]
                // A soft wrap split the line mid-flow; anything else is a
                // line the program broke at a space it then dropped.
                let soft = snapshot.rowWrapped.indices.contains(above.row)
                    && snapshot.rowWrapped[above.row]
                    && above.hi == cols - 1 && span.lo == 0
                if !soft { text.append(" ") }
            }
            text.append(grid.text(span))
        }

        return ColorRun(segments: spans.map { .init(row: $0.row, col: $0.lo, length: $0.hi - $0.lo + 1) },
                        text: text,
                        color: key.fg)
    }

    /// Does the run take in all the text on these rows?
    ///
    /// For settling a cell that also reads as a command block. A block the
    /// run covers is a fragment of a coloured passage — a TUI wrapped a
    /// sentence and the next row happened to open with `bash` — and the
    /// passage is the target. A run that only dots the block is a command
    /// highlighted token by token, and the command is.
    package static func run(_ run: ColorRun,
                            covers rows: ClosedRange<Int>,
                            in snapshot: TerminalSnapshot) -> Bool {
        let grid = Grid(snapshot: snapshot)
        return rows.allSatisfy { row in
            guard row >= 0, row < snapshot.rows,
                  let start = grid.contentStart(row),
                  let end = grid.contentEnd(row) else { return true }
            return run.segments.contains {
                $0.row == row && $0.col <= start && $0.col + $0.length - 1 >= end
            }
        }
    }

    // MARK: - grid reading

    private struct Key: Equatable {
        let fg: PackedColor
        let bg: PackedColor
    }

    /// One row's piece of the run, inclusive columns, blank edges trimmed.
    private struct Span {
        let row: Int
        let lo: Int
        let hi: Int
    }

    private struct Grid {
        let snapshot: TerminalSnapshot

        func cell(_ row: Int, _ col: Int) -> Cell {
            snapshot.cells[snapshot.rowStart(row) + col]
        }

        /// The leading half of a wide glyph when `col` is its trailing half,
        /// which carries no text and isn't what the colour was set on.
        func lead(_ row: Int, _ col: Int) -> Int {
            col > 0 && cell(row, col).isContinuation ? col - 1 : col
        }

        func key(_ row: Int, _ col: Int) -> Key {
            let c = cell(row, col)
            return Key(fg: c.fg, bg: c.bg)
        }

        /// Padding, as opposed to text. A continuation cell is text: it is
        /// half of a glyph.
        func isBlank(_ row: Int, _ col: Int) -> Bool {
            let c = cell(row, col)
            return c.scalar == " " && !c.isContinuation
        }

        /// Judged on the glyph a trailing half belongs to, so the tail of a
        /// wide glyph in another colour doesn't get pulled into the run.
        func matches(_ row: Int, _ col: Int, _ key: Key) -> Bool {
            self.key(row, lead(row, col)) == key
        }

        /// Text in the run's colours, as opposed to a space that happens to
        /// carry them.
        func isText(_ row: Int, _ col: Int, _ key: Key) -> Bool {
            !isBlank(row, col) && matches(row, col, key)
        }

        /// A single space whose background matches, with text of the run on
        /// both sides of it.
        func isGap(_ row: Int, _ col: Int, _ key: Key) -> Bool {
            col > 0 && col < snapshot.cols - 1
                && isBlank(row, col) && cell(row, col).bg == key.bg
                && isText(row, col - 1, key) && isText(row, col + 1, key)
        }

        /// The word left of `col` when `col` is a space the run would bridge.
        func bridgedGap(at col: Int, row: Int) -> Int? {
            guard col > 0, isBlank(row, col) else { return nil }
            let left = lead(row, col - 1)
            let key = self.key(row, left)
            guard isGap(row, col, key), !isColumnar(row, key) else { return nil }
            return left
        }

        /// Does this row separate things in the run's colour with runs of
        /// padding? Leading indent and trailing padding don't count: only a
        /// gap with the colour on both sides of it.
        func isColumnar(_ row: Int, _ key: Key) -> Bool {
            var col = 0
            var sawText = false
            while col < snapshot.cols {
                if isBlank(row, col) {
                    var end = col
                    while end < snapshot.cols, isBlank(row, end) { end += 1 }
                    if sawText, end - col >= 2, end < snapshot.cols,
                       isText(row, col - 1, key), isText(row, end, key) {
                        return true
                    }
                    col = end
                } else {
                    sawText = true
                    col += 1
                }
            }
            return false
        }

        func contentStart(_ row: Int) -> Int? {
            (0..<snapshot.cols).first { !isBlank(row, $0) }
        }

        func contentEnd(_ row: Int) -> Int? {
            (0..<snapshot.cols).last { !isBlank(row, $0) }
        }

        /// The same-coloured cells either side of `col`, with the spaces at
        /// either end dropped — a coloured sentence often carries a coloured
        /// space past its last word. Nil when there's nothing but spaces.
        func segment(through col: Int, row: Int, key: Key) -> Span? {
            let bridging = !isColumnar(row, key)
            func joins(_ c: Int) -> Bool {
                matches(row, c, key) || (bridging && isGap(row, c, key))
            }
            var lo = col, hi = col
            while lo > 0, joins(lo - 1) { lo -= 1 }
            while hi < snapshot.cols - 1, joins(hi + 1) { hi += 1 }
            while lo <= hi, isBlank(row, lo) { lo += 1 }
            while hi >= lo, isBlank(row, hi) { hi -= 1 }
            return lo <= hi ? Span(row: row, lo: lo, hi: hi) : nil
        }

        /// Did the line ending at `end` on one row carry on at `start` on the
        /// next? Always, when the terminal wrapped it. Otherwise only when the
        /// next row's first word wouldn't have fitted after this one — the
        /// reason a program breaks a line where it does.
        func runsOn(from row: Int, end: Int, to next: Int, start: Int) -> Bool {
            if snapshot.rowWrapped.indices.contains(row), snapshot.rowWrapped[row] { return true }
            var word = 0
            while start + word < snapshot.cols, !isBlank(next, start + word) { word += 1 }
            return end + 1 + word >= snapshot.cols - ColorRunDetector.wrapSlack
        }

        /// Whether a piece has a letter or digit in it. One that doesn't is
        /// decoration — the grey rule Claude Code draws across the window, a
        /// border — and is neither a target nor joined onto one: a full-width
        /// rule always passes the fit test, so it would otherwise fuse with
        /// whatever grey line sits under it.
        func hasWord(_ span: Span) -> Bool {
            (span.lo...span.hi).contains {
                CharacterSet.alphanumerics.contains(cell(span.row, $0).scalar)
            }
        }

        func text(_ span: Span) -> String {
            var out = ""
            for col in span.lo...span.hi where !cell(span.row, col).isContinuation {
                out.unicodeScalars.append(cell(span.row, col).scalar)
            }
            return out
        }
    }
}
