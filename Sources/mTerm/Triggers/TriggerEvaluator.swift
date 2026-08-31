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
            for r in row...last {
                let base = snapshot.rowStart(r)
                for col in 0..<cols {
                    let cell = snapshot.cells[base + col]
                    if cell.scalar.value <= 0xFFFF {
                        line.unicodeScalars.append(cell.scalar)
                    } else {
                        line.unicodeScalars.append(" ")
                    }
                }
            }

            defer { row = last + 1 }
            // Saves regex work on the mostly-empty rows that dominate a screen.
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            if claimed.count < ns.length {
                claimed = [Bool](repeating: false, count: ns.length)
            } else {
                for i in 0..<ns.length { claimed[i] = false }
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

                    // Every joined row contributed exactly `cols` units, so a
                    // position maps straight back to a row and column. One
                    // match becomes one band per row it crosses, each carrying
                    // the whole matched text so a click anywhere along it
                    // opens the whole thing rather than the visible half.
                    let text = ns.substring(with: NSRange(location: r.location,
                                                          length: matchEnd - r.location))
                    let matchID = nextMatchID
                    nextMatchID += 1
                    var p = r.location
                    while p < matchEnd {
                        let segCol = p % cols
                        let segLen = min(cols - segCol, matchEnd - p)
                        matches.append(TriggerMatch(
                            id: matchID,
                            trigger: trigger,
                            viewportCol: segCol,
                            viewportRow: row + p / cols,
                            length: segLen,
                            text: text
                        ))
                        p += segLen
                    }
                }
            }
        }
        return matches
    }
}
