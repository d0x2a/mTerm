import Foundation

/// Where a query matched a field, and how well.
struct FuzzyMatch {
    /// 0…1, from the bands in `Fuzzy`. One scale is shared by every kind of
    /// palette row on purpose: a tab title, an action label and a settings
    /// keyword all come back on the same scale, so the hub can rank them in a
    /// single list without a per-kind fudge factor.
    let score: Double
    /// Ranges of the field, as offsets into its `Character`s, that the query
    /// landed on. The row views bold exactly these.
    let ranges: [Range<Int>]
}

/// Subsequence-with-bands matching, used by every row the ⌘K hub can show.
///
/// The bands matter more than the algorithm. The gap between `wordPrefix` and
/// anything a subsequence can reach is what keeps ⏎ trustworthy: a tab that
/// merely contains the query's letters can never outrank an action the query
/// actually names. Where two matches land in the same band — "new" against
/// both **New Tab** and a tab in ~/newsletter — `coverageBonus` separates them
/// by how much of the field the query accounts for.
enum Fuzzy {
    static let exact = 1.0
    static let fieldPrefix = 0.95
    static let wordPrefix = 0.9
    static let substring = 0.8
    static let subsequenceFloor = 0.5
    /// Subsequence bonuses can't reach `substring`, so the bands never overlap.
    static let subsequenceCeiling = 0.68

    /// How much of a band a match can climb by covering more of its field.
    ///
    /// Without it "new" scores identically on the action **New Tab** and on a
    /// tab sitting in ~/newsletter — both are prefixes — and which one you get
    /// comes down to list order rather than to the match. Coverage breaks that
    /// the way a reader would: the query is most of "New Tab" and a third of
    /// "newsletter", so it is more plausibly a name for the first. Small enough
    /// that no band can reach the one above it.
    static let coverageBonus = 0.04

    /// `nil` when `query` isn't in `field` at all. `query` must already be
    /// lowercased and non-empty — the callers do it once per keystroke rather
    /// than once per candidate.
    static func match(_ field: String, query: [Character]) -> FuzzyMatch? {
        guard !query.isEmpty else { return nil }
        let hay = Array(field.lowercased())
        guard hay.count >= query.count else { return nil }

        // Coverage lifts a match within its band, never out of it.
        let coverage = Double(query.count) / Double(hay.count) * coverageBonus

        if hay == query { return FuzzyMatch(score: exact, ranges: [0..<query.count]) }
        if hasPrefix(hay, query, at: 0) {
            return FuzzyMatch(score: fieldPrefix + coverage, ranges: [0..<query.count])
        }
        // A word inside the field: "tab" should find "New Tab" as strongly as
        // the first word would, and "work/api" should find it inside a path.
        // Same rule SettingsIndex.rank has always used.
        for i in hay.indices where isWordStart(hay, i) {
            if hasPrefix(hay, query, at: i) {
                return FuzzyMatch(score: wordPrefix + coverage,
                                  ranges: [i..<(i + query.count)])
            }
        }
        for i in 0...(hay.count - query.count) where hasPrefix(hay, query, at: i) {
            return FuzzyMatch(score: substring + coverage,
                              ranges: [i..<(i + query.count)])
        }
        return subsequence(hay, query)
    }

    // MARK: internals

    private static func hasPrefix(_ hay: [Character], _ needle: [Character], at i: Int) -> Bool {
        guard i + needle.count <= hay.count else { return false }
        for k in needle.indices where hay[i + k] != needle[k] { return false }
        return true
    }

    /// True at the first character and after any non-alphanumeric — which
    /// makes every path segment a word start, so "smt" reaches
    /// "~/**s**ource/**mT**erm" through the separators.
    private static func isWordStart(_ hay: [Character], _ i: Int) -> Bool {
        if i == 0 { return true }
        return !hay[i - 1].isLetter && !hay[i - 1].isNumber
    }

    /// Greedy left-to-right subsequence. Greedy is the right call here because
    /// the fields are short and the *first* run of matches is the one a reader
    /// scanning left to right will look for; an optimal matcher would sometimes
    /// highlight a later, tidier run the eye never goes to.
    private static func subsequence(_ hay: [Character], _ query: [Character]) -> FuzzyMatch? {
        var ranges: [Range<Int>] = []
        var q = 0
        var wordStarts = 0
        for i in hay.indices where q < query.count {
            guard hay[i] == query[q] else { continue }
            if isWordStart(hay, i) { wordStarts += 1 }
            if let last = ranges.last, last.upperBound == i {
                ranges[ranges.count - 1] = last.lowerBound..<(i + 1)
            } else {
                ranges.append(i..<(i + 1))
            }
            q += 1
        }
        guard q == query.count else { return nil }

        // Two bonuses, both small: characters that land on word starts (an
        // initialism like "smt"), and a query that covers much of a short
        // field (so "api" prefers "api" over "…/api/deploy/scripts").
        let onStarts = Double(wordStarts) / Double(query.count)
        let density = Double(query.count) / Double(hay.count)
        let bonus = min(subsequenceCeiling - subsequenceFloor,
                        onStarts * 0.14 + density * 0.04)
        return FuzzyMatch(score: subsequenceFloor + bonus, ranges: ranges)
    }
}
