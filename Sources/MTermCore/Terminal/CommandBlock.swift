import Foundation

/// A run of rows on screen that looks like a command someone printed for you
/// to run, and what ⌘-click would put on the pasteboard.
package struct CommandBlock: Equatable {
    /// Viewport rows, inclusive — every row the block covers, including the
    /// continuation rows of anything that wrapped. This is the extent that
    /// gets marked, so what lights up is exactly what gets copied.
    package let firstRow: Int
    package let lastRow: Int
    /// Wrapped rows rejoined, the block's common indent removed, trailing
    /// padding trimmed. What lands on the pasteboard, ready to paste into a
    /// shell.
    package let text: String

    package init(firstRow: Int, lastRow: Int, text: String) {
        self.firstRow = firstRow
        self.lastRow = lastRow
        self.text = text
    }
}

/// Finds the command block under the pointer.
///
/// There is nothing in the bytes that says "this is a code block". A TUI that
/// renders markdown — Claude Code, say — prints the block's lines with no
/// styling of their own, so they are indistinguishable from prose at the cell
/// level. What is left to go on is shape and content: a run of non-blank rows
/// bounded by blank ones, whose first line reads like a command.
///
/// The content test is the same shape as the one behind ⌘-click on a file
/// path: a loose pattern, then a check against the world. There it is "does
/// this path exist"; here it is "does this name resolve to something you could
/// run". Without it, every paragraph on screen — prose, `git status` output,
/// an error message — becomes a copy target.
package enum CommandBlockDetector {
    /// How far into a line a flag still counts as a command's flag rather
    /// than a sentence mentioning one.
    package static let flagLookahead = 4

    /// Past this, a run of non-blank rows is a wall of output rather than a
    /// command, and marking it would light up most of the window.
    package static let maxRows = 40

    /// Gutter decorations a TUI puts in front of the first line of a block.
    /// Treated as indent rather than content: the bullet is the renderer
    /// talking, not part of the command.
    private static let gutterGlyphs: Set<Character> = ["⏺", "●", "⎿", "│", "▌", "▏", ">", "|"]

    package static func block(containingRow row: Int,
                              snapshot: TerminalSnapshot,
                              isExecutable: (String) -> Bool) -> CommandBlock? {
        let lines = logicalLines(snapshot)
        guard let hit = lines.firstIndex(where: { $0.firstRow <= row && row <= $0.lastRow }),
              !isBlank(lines[hit])
        else { return nil }

        // Grow over neighbouring non-blank lines. A blank row is the only
        // boundary available: nothing in the stream marks where a code block
        // starts or ends.
        //
        // Unless the pointer is inside a heredoc body, which may itself hold
        // blank lines. Then the run does not begin at the nearest blank above
        // — it begins at the line that opened the heredoc.
        var first = hit, last = hit
        if let opener = heredocOpener(enclosing: hit, in: lines) {
            first = opener
        } else {
            while first > 0, !isBlank(lines[first - 1]) { first -= 1 }
        }
        while last < lines.count - 1, !isBlank(lines[last + 1]) { last += 1 }

        // A heredoc body can hold blank lines, and a blank line is otherwise
        // exactly where a run stops. Carry on to the terminator when one is
        // still open, so the body doesn't get cut in half.
        if let delimiter = openHeredoc(in: lines[first...last].map(\.text)) {
            var probe = last
            while probe < lines.count - 1,
                  lines[probe].lastRow - lines[first].firstRow + 1 < maxRows {
                probe += 1
                if lines[probe].text.trimmingCharacters(in: .whitespaces) == delimiter {
                    last = probe
                    break
                }
            }
        }

        let run = Array(lines[first...last])
        guard run[run.count - 1].lastRow - run[0].firstRow + 1 <= maxRows else { return nil }

        // The gutter glyph sits where indentation would be, so blanking it
        // keeps the first line aligned with the rest for the indent maths.
        var texts = run.map(\.text)
        texts[0] = strippingGutter(texts[0])

        // A run is rarely one thing. A TUI prints a numbered heading and the
        // command it describes with no blank line between them, so the run
        // holds prose *and* command. Split it and keep the group under the
        // pointer — the heading is not what ⌘-click should copy.
        guard let group = group(containing: hit - first, in: texts, isExecutable: isExecutable)
        else { return nil }

        return CommandBlock(firstRow: run[group.lowerBound].firstRow,
                            lastRow: run[group.upperBound].lastRow,
                            text: text(of: Array(texts[group])))
    }

    /// What a set of lines becomes on the pasteboard: the common indent gone,
    /// row padding trimmed, and the prompt off the first line.
    ///
    /// Taken as lines rather than as a detected block, because the sheet lets
    /// the extent be adjusted by hand and the result has to be treated the
    /// same way whatever chose it.
    package static func text(of lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        let indent = commonIndent(lines)
        var body = lines.map { line -> String in
            let trimmed = String(line.dropFirst(min(indent, leadingSpaces(line))))
            return trimmed.replacingOccurrences(of: " +$", with: "", options: .regularExpression)
        }
        if let bare = strippingPrompt(body[0]) { body[0] = bare }
        return body.joined(separator: "\n")
    }

    /// The text for an arbitrary span of logical lines, for the sheet's
    /// adjustment controls. The first line keeps its gutter glyph stripped
    /// only when it is the one the renderer decorated.
    package static func text(ofLines span: ClosedRange<Int>,
                             in lines: [LogicalLine]) -> String {
        guard !lines.isEmpty else { return "" }
        let clamped = max(0, span.lowerBound)...min(lines.count - 1, span.upperBound)
        var texts = clamped.map { lines[$0].text }
        texts[0] = strippingGutter(texts[0])
        return text(of: texts)
    }

    /// The command group around `index`, or nil when the pointer is on the
    /// prose that shares a run with one.
    ///
    /// A group starts at a line that reads like a command and takes the lines
    /// it runs onto. It also takes a command that directly follows one, since
    /// consecutive commands in a block were written to be run together — but
    /// only when the group did not start at a prompt. A prompt means a
    /// transcript, and the line after a transcript's command is its output.
    package static func group(containing index: Int,
                              in texts: [String],
                              isExecutable: (String) -> Bool) -> ClosedRange<Int>? {
        var i = 0
        while i < texts.count {
            // `i > 0` here always means prose above it: a command directly
            // after a command is taken by the extension below, never reached
            // as a fresh group.
            guard looksLikeCommand(texts[i], isExecutable: isExecutable,
                                   requiringSyntax: i > 0) else {
                i += 1
                continue
            }
            let start = i
            let transcript = strippingPrompt(texts[i]) != nil
            var joined = texts[i]
            var heredoc = heredocDelimiter(texts[i])
            while i < texts.count - 1 {
                // Everything up to the terminator belongs to the command,
                // whatever it looks like — that is the point of a heredoc.
                if let delimiter = heredoc {
                    i += 1
                    joined += "\n" + texts[i]
                    if texts[i].trimmingCharacters(in: .whitespaces) == delimiter { heredoc = nil }
                    continue
                }
                guard continues(texts[i])
                        || isIncomplete(joined)
                        || (!transcript && looksLikeCommand(texts[i + 1], isExecutable: isExecutable))
                else { break }
                i += 1
                joined += "\n" + texts[i]
                heredoc = heredocDelimiter(texts[i])
            }
            if (start...i).contains(index) { return start...i }
            i += 1
        }
        return nil
    }

    /// Does this line read like something you would run?
    ///
    /// Deliberately an `or`: the `$PATH` check alone misses a command for a
    /// tool that isn't installed here, which is common for anything printed
    /// for a remote machine, and those almost always carry a flag.
    /// `requiringSyntax` is for a line with prose above it inside the same run.
    /// Plenty of English words are also commands — `at`, `test`, `time`,
    /// `make`, `find`, `date` — so in the middle of a paragraph the name alone
    /// proves nothing and the line has to show some shell in it. A line that
    /// opens a run is judged on the name, which is what lets `pulumi up` at the
    /// start of a block count while "at ssh. The bang is…" mid-sentence does not.
    package static func looksLikeCommand(_ rawLine: String,
                                        isExecutable: (String) -> Bool,
                                        requiringSyntax: Bool = false) -> Bool {
        // Judge the command, not the prompt it was shown behind — otherwise
        // `! ssh host uptime` is measured as though `!` were its name.
        let line = strippingPrompt(rawLine) ?? rawLine
        var tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // A root prompt, and environment assignments in front of the command,
        // are not the command's name either. `#` is dropped only here: it is
        // left in the text, where it may well be a comment.
        if let head = tokens.first, head == "#" { tokens.removeFirst() }
        while let head = tokens.first, head.contains("="), !head.hasPrefix("-") { tokens.removeFirst() }
        if let head = tokens.first, head == "sudo" || head == "doas" { tokens.removeFirst() }
        guard let name = tokens.first, !name.isEmpty else { return false }

        let named = isExecutable(name)

        // A flag, but only near the front. A command reaches its first flag
        // within a word or two — `git log --graph`, `terraform apply
        // -auto-approve` — whereas prose that happens to mention one gets
        // there late: "two spaces indent saying --namespace ahead" is the
        // echo of a sentence, not something to run.
        let flag = tokens.prefix(Self.flagLookahead).contains {
            $0.range(of: #"^-{1,2}[A-Za-z]"#, options: .regularExpression) != nil
        }
        // `continues` rather than `hasSuffix`: these lines come off the grid
        // with the row's trailing padding still on them, so a command ending
        // in a backslash does not end in one as a string.
        let shell = flag
            || line.contains(" | ")
            || continues(line)
            || heredocDelimiter(line) != nil

        if requiringSyntax {
            // A path or an assignment is evidence too, but only alongside a
            // name that resolves: prose is full of slashes.
            let argumentShaped = tokens.dropFirst().contains {
                $0.contains("/") || $0.contains("=")
            }
            return shell || (named && argumentShaped)
        }
        return named || shell
    }

    /// The command without its prompt, or nil when the line doesn't carry one.
    ///
    /// `!` is here because a TUI that runs shell commands for you echoes them
    /// with it — Claude Code's bash mode does — and `!` pasted into an
    /// interactive shell is history expansion, not the command that was shown.
    ///
    /// `#` is deliberately absent. It is a root prompt in a transcript and a
    /// comment everywhere else, and mistaking a comment for a prompt silently
    /// removes the `#` that made it one.
    private static let promptSigils: Set<Character> = ["$", "%", ">", "❯", "➜", "!"]

    package static func strippingPrompt(_ line: String) -> String? {
        var rest = Substring(line)
        while rest.first == " " { rest = rest.dropFirst() }
        guard let sigil = rest.first, promptSigils.contains(sigil) else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " else { return nil }   // "$FOO" is a variable
        while rest.first == " " { rest = rest.dropFirst() }
        return rest.isEmpty ? nil : String(rest)
    }

    /// Does this line hand the command on to the next one?
    package static func continues(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasSuffix("\\")
            || trimmed.hasSuffix("|")
            || trimmed.hasSuffix("&&")
            || trimmed.hasSuffix("||")
    }

    /// The delimiter of a heredoc this line opens, if it opens one.
    ///
    /// `cat <<'EOF' | kubectl apply -f -` is a command whose argument is
    /// everything up to the terminator. Copying the first line alone gives a
    /// command that sits waiting on stdin.
    package static func heredocDelimiter(_ line: String) -> String? {
        let pattern = #"<<-?\s*(?:'([A-Za-z_]\w*)'|"([A-Za-z_]\w*)"|([A-Za-z_]\w*))"#
        guard let match = line.range(of: pattern, options: .regularExpression) else { return nil }
        let opener = String(line[match])
        // Whatever followed the `<<`, minus the dash, the quotes and the space.
        var delimiter = opener.replacingOccurrences(of: "<<-", with: "")
            .replacingOccurrences(of: "<<", with: "")
            .trimmingCharacters(in: .whitespaces)
        delimiter = delimiter.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        return delimiter.isEmpty ? nil : delimiter
    }

    /// The line that opened the heredoc `index` sits inside, if it sits in one.
    ///
    /// Looks back past blank lines, which a body is allowed to contain, and
    /// stops if it finds the terminator first — that heredoc closed before the
    /// pointer and has nothing to do with it.
    package static func heredocOpener(enclosing index: Int, in lines: [LogicalLine]) -> Int? {
        var scanned = 0
        var j = index - 1
        while j >= 0, scanned < maxRows {
            if let delimiter = heredocDelimiter(lines[j].text) {
                let terminated = ((j + 1)..<index).contains {
                    lines[$0].text.trimmingCharacters(in: .whitespaces) == delimiter
                }
                return terminated ? nil : j
            }
            // A terminator above us closes whatever came before it.
            j -= 1
            scanned += 1
        }
        return nil
    }

    /// The delimiter of a heredoc left open by these lines, if any.
    package static func openHeredoc(in texts: [String]) -> String? {
        var pending: String?
        for line in texts {
            if let delimiter = pending {
                if line.trimmingCharacters(in: .whitespaces) == delimiter { pending = nil }
                continue
            }
            pending = heredocDelimiter(line)
        }
        return pending
    }

    /// Is the command unfinished — still inside a quote or a bracket?
    ///
    /// A backslash is not the only way a command runs on. The common case in
    /// anything kubectl-shaped is a JSON payload handed to `-p`, where the
    /// line simply ends mid-quote:
    ///
    ///     kubectl patch deploy app --type=json -p '[{"op":"add",
    ///       "path":"/spec/template/spec/containers/0/env/0", …
    ///
    /// Copying only the first line of that is worse than copying nothing: it
    /// looks like a command and is broken.
    package static func isIncomplete(_ text: String) -> Bool {
        var single = false, double = false, depth = 0, escaped = false
        for ch in text {
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "'" , !double { single.toggle(); continue }
            if ch == "\"", !single { double.toggle(); continue }
            guard !single, !double else { continue }
            if ch == "[" || ch == "{" || ch == "(" { depth += 1 }
            if ch == "]" || ch == "}" || ch == ")" { depth = max(0, depth - 1) }
        }
        return single || double || depth > 0
    }

    // MARK: - shape

    package struct LogicalLine: Equatable {
        package let firstRow: Int
        package let lastRow: Int
        package let text: String
    }

    /// The viewport as logical lines: a row that ran out of width is joined to
    /// the one it continues onto, the same way the trigger evaluator does it,
    /// so a wrapped command is one line rather than two fragments.
    package static func logicalLines(_ snapshot: TerminalSnapshot) -> [LogicalLine] {
        guard snapshot.cols > 0 else { return [] }
        var lines: [LogicalLine] = []
        var row = 0
        while row < snapshot.rows {
            var last = row
            while last < snapshot.rows - 1,
                  snapshot.rowWrapped.indices.contains(last),
                  snapshot.rowWrapped[last] {
                last += 1
            }
            var text = ""
            text.reserveCapacity(snapshot.cols * (last - row + 1))
            for r in row...last {
                let base = snapshot.rowStart(r)
                for col in 0..<snapshot.cols {
                    let cell = snapshot.cells[base + col]
                    text.unicodeScalars.append(cell.scalar.value <= 0xFFFF ? cell.scalar : " ")
                }
            }
            lines.append(LogicalLine(firstRow: row, lastRow: last, text: text))
            row = last + 1
        }
        return lines
    }

    private static func isBlank(_ line: LogicalLine) -> Bool {
        line.text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func strippingGutter(_ line: String) -> String {
        var chars = Array(line)
        var i = 0
        while i < chars.count, chars[i] == " " { i += 1 }
        guard i < chars.count, gutterGlyphs.contains(chars[i]) else { return line }
        chars[i] = " "
        return String(chars)
    }

    private static func leadingSpaces(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private static func commonIndent(_ lines: [String]) -> Int {
        lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
             .map(leadingSpaces)
             .min() ?? 0
    }
}
