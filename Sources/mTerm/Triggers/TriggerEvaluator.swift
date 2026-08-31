import Foundation

struct TriggerMatch {
    /// Shared by every segment of one regex match. A link that wraps is
    /// reported as one band per row it crosses; they carry the same id so a
    /// consumer can treat them as the single link they are — hovering any
    /// row of a wrapped URL underlines all of it, not just the row under the
    /// pointer. Unique within one `evaluate` call, not across calls.
    let id: Int
    let trigger: Trigger
    let viewportCol: Int           // first cell
    let viewportRow: Int
    let length: Int                // number of cells
    let text: String               // matched substring
    /// Target of the OSC 8 this match came from, when it came from one. A
    /// pattern match leaves it nil and its text gets interpreted — a scheme
    /// guessed, a relative path resolved. An explicit hyperlink is used
    /// exactly as the program sent it, because it isn't a guess.
    let hyperlink: String?

    init(id: Int, trigger: Trigger, viewportCol: Int, viewportRow: Int,
         length: Int, text: String, hyperlink: String? = nil) {
        self.id = id
        self.trigger = trigger
        self.viewportCol = viewportCol
        self.viewportRow = viewportRow
        self.length = length
        self.text = text
        self.hyperlink = hyperlink
    }
}

/// Compiles trigger regexes once and runs them against the visible viewport
/// each frame. The cell→string mapping is exact (each cell scalar maps to
/// one UTF-16 code unit, since the parser skips non-BMP scalars), so regex
/// match locations are directly cell column indexes.
final class TriggerEvaluator {
    private var compiled: [(Trigger, NSRegularExpression)] = []

    var triggers: [Trigger] = [] {
        didSet { recompile() }
    }

    init(triggers: [Trigger] = Trigger.builtins) {
        self.triggers = triggers
        recompile()
    }

    private func recompile() {
        compiled = triggers.compactMap { t in
            guard t.enabled,
                  let regex = try? NSRegularExpression(pattern: t.pattern)
            else { return nil }
            return (t, regex)
        }
    }

    func evaluate(snapshot: TerminalSnapshot) -> [TriggerMatch] {
        guard !compiled.isEmpty, snapshot.cols > 0 else { return [] }

        let cols = snapshot.cols
        var matches: [TriggerMatch] = []
        var line = ""
        line.reserveCapacity(cols)
        // Link id per position in `line`, so an OSC 8 run can be found by the
        // same index arithmetic a regex match uses. Only gathered when the
        // session has actually seen an OSC 8 — otherwise this is an append per
        // cell per frame for a feature nothing on screen is using.
        let hasLinks = !snapshot.links.isEmpty
        var linkRun: [UInt16] = []
        if hasLinks { linkRun.reserveCapacity(cols * snapshot.rows) }
        // Cells already taken by an earlier trigger on this logical line.
        // Triggers are tried in order, so the first to claim a span keeps it:
        // the URL rule wins `https://host/path` outright and the file-path
        // rule never gets a second band onto the same cells.
        var claimed = [Bool](repeating: false, count: cols)

        var nextMatchID = 0
        var row = 0
        while row < snapshot.rows {
            // A row that ran out of width continues onto the next one, so a
            // logical line can span several viewport rows. Match against the
            // join rather than the pieces — a URL broken across a wrap is one
            // URL, and matching per-row would see two fragments, link only
            // the first, and hand ⌘-click half an address.
            var last = row
            while last < snapshot.rows - 1,
                  snapshot.rowWrapped.indices.contains(last),
                  snapshot.rowWrapped[last] {
                last += 1
            }

            line.removeAll(keepingCapacity: true)
            linkRun.removeAll(keepingCapacity: true)
            for r in row...last {
                let base = snapshot.rowStart(r)
                for col in 0..<cols {
                    let cell = snapshot.cells[base + col]
                    if cell.scalar.value <= 0xFFFF {
                        line.unicodeScalars.append(cell.scalar)
                    } else {
                        line.unicodeScalars.append(" ")
                    }
                    if hasLinks { linkRun.append(cell.link) }
                }
            }

            defer { row = last + 1 }
            // Saves regex work on the mostly-empty rows that dominate a screen.
            // A blank row can still carry a hyperlink — OSC 8 marks cells, not
            // words — so only skip when there is no link on it either.
            if line.trimmingCharacters(in: .whitespaces).isEmpty,
               !linkRun.contains(where: { $0 != 0 }) { continue }

            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            if claimed.count < ns.length {
                claimed = [Bool](repeating: false, count: ns.length)
            } else {
                for i in 0..<ns.length { claimed[i] = false }
            }

            // OSC 8 hyperlinks aren't pattern-matched: the program said where
            // the link is and what it points at, so they claim their cells
            // before any regex is allowed to look at them. One band per
            // contiguous run — ids are interned by target, and banding a run
            // rather than an id keeps two mentions of one URL from lighting up
            // together.
            let linkEnd = min(linkRun.count, ns.length)
            var pos = 0
            while pos < linkEnd {
                let id = linkRun[pos]
                guard id != 0, Int(id) <= snapshot.links.count else {
                    pos += 1
                    continue
                }
                var end = pos
                while end < linkEnd, linkRun[end] == id { end += 1 }
                for i in pos..<end { claimed[i] = true }
                let text = ns.substring(with: NSRange(location: pos, length: end - pos))
                matches.append(contentsOf: bands(
                    from: pos, to: end, row: row, cols: cols,
                    id: nextMatchID, trigger: .hyperlink, text: text,
                    hyperlink: snapshot.links[Int(id) - 1]
                ))
                nextMatchID += 1
                pos = end
            }

            for (trigger, regex) in compiled {
                for m in regex.matches(in: line, range: full) {
                    let r = m.range
                    if r.location == NSNotFound || r.length == 0 { continue }
                    let matchEnd = min(r.location + r.length, ns.length)
                    guard r.location < matchEnd else { continue }
                    var free = true
                    for i in r.location..<matchEnd where claimed[i] { free = false; break }
                    guard free else { continue }
                    for i in r.location..<matchEnd { claimed[i] = true }

                    let text = ns.substring(with: NSRange(location: r.location,
                                                          length: matchEnd - r.location))
                    matches.append(contentsOf: bands(
                        from: r.location, to: matchEnd, row: row, cols: cols,
                        id: nextMatchID, trigger: trigger, text: text,
                        hyperlink: nil
                    ))
                    nextMatchID += 1
                }
            }
        }
        return matches
    }

    /// Splits one match over the viewport rows it crosses. Every joined row
    /// contributed exactly `cols` units, so a position in the joined line maps
    /// straight back to a row and column. Each band carries the whole matched
    /// text and shares one id, so a click anywhere along a wrapped link opens
    /// the whole thing rather than the visible half, and hovering marks all of
    /// it rather than the row under the pointer.
    private func bands(from start: Int, to end: Int, row: Int, cols: Int,
                       id: Int, trigger: Trigger, text: String,
                       hyperlink: String?) -> [TriggerMatch] {
        var out: [TriggerMatch] = []
        var p = start
        while p < end {
            let segCol = p % cols
            let segLen = min(cols - segCol, end - p)
            out.append(TriggerMatch(
                id: id,
                trigger: trigger,
                viewportCol: segCol,
                viewportRow: row + p / cols,
                length: segLen,
                text: text,
                hyperlink: hyperlink
            ))
            p += segLen
        }
        return out
    }
}
