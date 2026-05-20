import Foundation

struct TriggerMatch {
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
        guard !compiled.isEmpty else { return [] }

        var matches: [TriggerMatch] = []
        var line = ""
        line.reserveCapacity(snapshot.cols)

        for row in 0..<snapshot.rows {
            line.removeAll(keepingCapacity: true)
            for col in 0..<snapshot.cols {
                let cell = snapshot.cells[row * snapshot.cols + col]
                if cell.scalar.value <= 0xFFFF {
                    line.unicodeScalars.append(cell.scalar)
                } else {
                    line.unicodeScalars.append(" ")
                }
            }
            // Strip trailing spaces — saves regex work on mostly-empty rows.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            for (trigger, regex) in compiled {
                for m in regex.matches(in: line, range: full) {
                    let r = m.range
                    if r.location == NSNotFound || r.length == 0 { continue }
                    matches.append(TriggerMatch(
                        trigger: trigger,
                        viewportCol: r.location,
                        viewportRow: row,
                        length: r.length,
                        text: ns.substring(with: r)
                    ))
                }
            }
        }
        return matches
    }
}
