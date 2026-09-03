import Foundation
import Testing
@testable import Sill

@Test func tiersOrderPrefixBeforeSubstringBeforeFuzzy() {
    #expect(FuzzyMatcher.match("che", in: "checkout")?.tier == 4)
    #expect(FuzzyMatcher.match("Che", in: "checkout")?.tier == 3)
    #expect(FuzzyMatcher.match("eck", in: "checkout")?.tier == 2)
    #expect(FuzzyMatcher.match("chk", in: "checkout")?.tier == 1)
    #expect(FuzzyMatcher.match("xyz", in: "checkout") == nil)
    // Nothing typed matches everything, without claiming any character.
    #expect(FuzzyMatcher.match("", in: "anything") == FuzzyMatcher.Match(tier: 3, score: 0, offsets: []))
}

@Test func fuzzyNeedsTwoCharacters() {
    // A single letter never matches by subsequence — that would light up every row.
    #expect(FuzzyMatcher.match("k", in: "checkout")?.tier == 2)   // substring is fine
    #expect(FuzzyMatcher.match("z", in: "checkout") == nil)
    #expect(FuzzyMatcher.match("ct", in: "checkout")?.tier == 1)
}

@Test func matchedOffsetsPointAtTheRightCharacters() {
    #expect(FuzzyMatcher.match("che", in: "checkout")?.offsets == [0, 1, 2])
    #expect(FuzzyMatcher.match("out", in: "checkout")?.offsets == [5, 6, 7])
    let fuzzy = FuzzyMatcher.match("rb", in: "rebase")
    #expect(fuzzy?.offsets == [0, 2])
}

@Test func fuzzyPrefersWordStartsAndRuns() {
    // "gco" should land on the g, c and o that begin words in "git-checkout"…
    let words = FuzzyMatcher.match("gco", in: "git-checkout")!
    #expect(words.offsets == [0, 4, 9])
    // …and outrank a candidate where the same letters are scattered.
    let scattered = FuzzyMatcher.match("gco", in: "gecko-tool")!
    #expect(words.score > scattered.score)
    // Consecutive letters beat the same letters spread out.
    let run = FuzzyMatcher.match("ase", in: "rebase")!       // substring tier
    let spread = FuzzyMatcher.match("ase", in: "a-s-e-x")!   // fuzzy tier
    #expect(run.rank > spread.rank)
}

@Test func optionDashesDoNotCountAsFuzzyMatches() {
    #expect(FuzzyMatcher.match("--a", in: "--message") == nil)     // "a" alone is too little
    #expect(FuzzyMatcher.match("--a", in: "--amend")?.tier == 4)
    #expect(FuzzyMatcher.match("-m", in: "--message")?.tier == 2)  // substring, as before
    #expect(FuzzyMatcher.match("--msg", in: "--message")?.tier == 1)
    #expect(FuzzyMatcher.match("--msg", in: "--message")?.offsets == [2, 4, 7])
    #expect(FuzzyMatcher.match("ms", in: "--message") == nil)      // a flag needs its dashes
}

@Test func rankIsTierFirst() {
    let prefix = FuzzyMatcher.match("re", in: "rebase")!
    let fuzzy = FuzzyMatcher.match("rb", in: "rebase")!
    #expect(prefix.rank > fuzzy.rank)
    #expect(fuzzy.rank >= 1_000 && fuzzy.rank < 2_000)
}

@Test func parserListsFuzzyMatchesLastAndMarksThem() {
    let parser = makeParser()
    // "ckt": no prefix or substring in the mini spec; only checkout by subsequence.
    let result = parser.complete(buffer: "git ckt", cursor: 7)
    #expect(result.suggestions.map(\.display) == ["checkout"])
    #expect(result.suggestions[0].matchedOffsets == [0, 4, 7])

    // "co": "commit" (prefix) before "checkout" (fuzzy).
    let mixed = parser.complete(buffer: "git co", cursor: 6)
    #expect(mixed.suggestions.map(\.display).prefix(2) == ["commit", "checkout"])
}

@Test func generatorOutputIsFilteredFuzzilyInStableOrder() {
    let items = ["feature/login", "main", "fix/logging", "release"].map {
        Suggestion(display: $0, insertText: $0, deleteCount: 0, detail: "", kind: .argument)
    }
    #expect(GeneratorRunner.matching(items, query: "log").map(\.display) == ["feature/login", "fix/logging"])
    // "flg": both by subsequence; the generator's order is kept among equals
    // unless the score says otherwise — "fix/logging" has l starting a word.
    let fuzzy = GeneratorRunner.matching(items, query: "flg").map(\.display)
    #expect(Set(fuzzy) == ["feature/login", "fix/logging"])
    #expect(fuzzy.first == "fix/logging")
}
