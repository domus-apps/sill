import Foundation

/* How a typed partial is matched against a candidate, in one place for
   every list (subcommands, options, command names, generator output,
   files). Four tiers, best first — the first three are what Sill always
   did, the fourth is fuzzy:

     4  exact-case prefix          "che"  → "checkout"
     3  case-insensitive prefix    "Che"  → "checkout"
     2  substring                  "eck"  → "checkout"
     1  subsequence (≥ 2 chars)    "chk"  → "checkout", "rb" → "rebase"

   A candidate's tier decides its place; within the fuzzy tier an fzf-style
   score prefers matches that are consecutive and that start words, so
   "gco" finds "git-checkout" before "gecko". Cost is a few thousand
   character comparisons per keystroke — well under the sort that follows. */
enum FuzzyMatcher {
    struct Match: Equatable {
        /// 4…1 as above; higher is better.
        var tier: Int
        /// Orders candidates inside the fuzzy tier; 0 elsewhere.
        var score: Int
        /// Character offsets of `candidate` that the query accounts for.
        var offsets: [Int]

        /// Combined for sorting: the tier dominates, the score refines.
        var rank: Int { tier * 1_000 + score }
    }

    static func match(_ query: String, in candidate: String) -> Match? {
        if query.isEmpty { return Match(tier: 3, score: 0, offsets: []) }
        let queryChars = Array(query)
        let candidateChars = Array(candidate)
        guard queryChars.count <= candidateChars.count else { return nil }

        if candidate.hasPrefix(query) {
            return Match(tier: 4, score: 0, offsets: Array(0..<queryChars.count))
        }
        let lowerQuery = queryChars.map { Character($0.lowercased()) }
        let lowerCandidate = candidateChars.map { Character($0.lowercased()) }
        if Array(lowerCandidate.prefix(lowerQuery.count)) == lowerQuery {
            return Match(tier: 3, score: 0, offsets: Array(0..<queryChars.count))
        }
        if let start = firstOccurrence(of: lowerQuery, in: lowerCandidate) {
            return Match(tier: 2, score: 0, offsets: Array(start..<(start + lowerQuery.count)))
        }
        /* Options: the dashes every candidate shares say nothing, so the
           fuzzy tier works on what follows them — "--a" is one real
           character, not three, and must not light up "--message". */
        let queryDashes = lowerQuery.prefix(while: { $0 == "-" }).count
        let candidateDashes = lowerCandidate.prefix(while: { $0 == "-" }).count
        let queryCore = Array(lowerQuery.dropFirst(queryDashes))
        let candidateCore = Array(lowerCandidate.dropFirst(candidateDashes))
        guard queryCore.count >= 2, (queryDashes == 0) == (candidateDashes == 0),
              let (score, offsets) = subsequence(queryCore, in: candidateCore)
        else { return nil }
        return Match(tier: 1, score: score, offsets: offsets.map { $0 + candidateDashes })
    }

    private static func firstOccurrence(of needle: [Character], in haystack: [Character]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<(start + needle.count)]) == needle {
            return start
        }
        return nil
    }

    /* The best-scoring way to spread the query over the candidate, by
       dynamic programming over (query index, candidate index). Landing on a
       word start earns the most, continuing a run earns some, and every
       skipped candidate character between two matched ones costs a little.
       Candidates are short, so the table is small. */
    private static let boundaryBonus = 8
    private static let consecutiveBonus = 4
    private static let gapPenalty = 1

    private static func subsequence(_ query: [Character], in candidate: [Character])
        -> (score: Int, offsets: [Int])?
    {
        let m = query.count, n = candidate.count
        let none = Int.min / 4
        // best[i][j]: best score matching query[..i] with query[i] at candidate[j].
        var best = Array(repeating: Array(repeating: none, count: n), count: m)
        var from = Array(repeating: Array(repeating: -1, count: n), count: m)

        for j in 0..<n where candidate[j] == query[0] {
            best[0][j] = bonus(at: j, in: candidate) - j * gapPenalty
        }
        for i in 1..<max(m, 1) {
            var bestPrev = none, bestPrevAt = -1
            for j in 1..<n {
                // Candidates for query[i-1] end anywhere before j.
                if best[i - 1][j - 1] > bestPrev {
                    bestPrev = best[i - 1][j - 1]
                    bestPrevAt = j - 1
                }
                guard candidate[j] == query[i], bestPrev != none else { continue }
                let consecutive = best[i - 1][j - 1] != none
                    ? best[i - 1][j - 1] + consecutiveBonus + bonus(at: j, in: candidate)
                    : none
                let gapped = bestPrev + bonus(at: j, in: candidate) - (j - bestPrevAt - 1) * gapPenalty
                if consecutive >= gapped {
                    best[i][j] = consecutive
                    from[i][j] = j - 1
                } else {
                    best[i][j] = gapped
                    from[i][j] = bestPrevAt
                }
            }
        }
        guard let (endJ, score) = best[m - 1].enumerated().max(by: { $0.element < $1.element }),
              score != none
        else { return nil }
        var offsets = [endJ]
        var i = m - 1, j = endJ
        while i > 0 {
            j = from[i][j]
            offsets.append(j)
            i -= 1
        }
        return (score, offsets.reversed())
    }

    /// A word start: the first character, or one right after a separator.
    private static func bonus(at index: Int, in candidate: [Character]) -> Int {
        guard index > 0 else { return boundaryBonus }
        let previous = candidate[index - 1]
        if "-_./: ".contains(previous) { return boundaryBonus }
        return 0
    }
}
