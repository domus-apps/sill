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

// MARK: - Terminal padding, from frames measured on the real apps

@Test func paddingPrefersTheDefaultWhenTheNumbersAllowIt() {
    let cell = CGSize(width: 8, height: 17)
    // Ghostty, one pane: 666x432 view around a 82x25 grid (656x425).
    #expect(CaretLocator.padding(view: CGSize(width: 666, height: 432),
                                 text: CGSize(width: 656, height: 425), cell: cell) == 2)
    // cmux, one pane: 669x691 around 664x680.
    #expect(CaretLocator.padding(view: CGSize(width: 669, height: 691),
                                 text: CGSize(width: 664, height: 680), cell: cell) == 2)
    // A configured 10pt padding leaves too much slack for the default.
    let wide = CaretLocator.padding(view: CGSize(width: 656 + 20 + 5, height: 425 + 20 + 9),
                                    text: CGSize(width: 656, height: 425), cell: cell)
    #expect(wide > 8 && wide < 13)
    // Nothing reported, or a view smaller than its own grid: fall back.
    #expect(CaretLocator.padding(view: CGSize(width: 666, height: 432),
                                 text: .zero, cell: cell) == 2)
    #expect(CaretLocator.padding(view: CGSize(width: 100, height: 100),
                                 text: CGSize(width: 656, height: 425), cell: cell) == 2)
}

@Test func displayWidthCountsWideCharactersAsTwoCells() {
    #expect(CaretLocator.displayWidth(of: "domus ❯ ") == 8)
    #expect(CaretLocator.displayWidth(of: "git checkout") == 12)
    #expect(CaretLocator.displayWidth(of: "한글") == 4)
    #expect(CaretLocator.displayWidth(of: "프로젝트 ❯ ") == 11)
    #expect(CaretLocator.displayWidth(of: "") == 0)
}

@Test func screenRowsCountWrappedLines() {
    // A 28-column pane, the shape of one quarter of a split Ghostty window:
    // the login banner is 42 cells and takes two rows, so the prompt after
    // it is on row 3 — not row 2, which is all the lines themselves say.
    let banner = "Last login: Thu Sep  3 15:43:01 on ttys039"
    #expect(CaretLocator.displayWidth(of: banner) == 42)
    #expect(CaretLocator.wrappedRowsForTesting(banner, cols: 28) == 2)
    #expect(CaretLocator.wrappedRowsForTesting("~ ❯ bun ", cols: 28) == 1)
    #expect(CaretLocator.wrappedRowsForTesting("", cols: 28) == 1)
    // A line filling the width exactly stays on one row.
    #expect(CaretLocator.wrappedRowsForTesting(String(repeating: "x", count: 28), cols: 28) == 1)
    #expect(CaretLocator.wrappedRowsForTesting(String(repeating: "x", count: 29), cols: 28) == 2)
}

@Test func theWholeWordOutranksEverythingIncludingRecency() {
    #expect(FuzzyMatcher.match("ls", in: "ls")?.tier == 5)
    #expect(FuzzyMatcher.match("ls", in: "lsof")?.tier == 4)
    // In a list, the exact word comes first even when the other was picked recently.
    let recency = RecencyStore(defaults: nil)
    recency.record(command: "", display: "lsof")
    var parser = makeParser()
    parser.recency = recency
    parser.commands = FixedCatalogForFuzzy(entries: [("lsof", "List open files"), ("ls", "List directory contents")])
    #expect(parser.complete(buffer: "ls", cursor: 2).suggestions.map(\.display) == ["ls", "lsof"])
}

private struct FixedCatalogForFuzzy: CommandCatalogProviding {
    var entries: [(name: String, description: String)]
    func commands(matching prefix: String, searchPath: String) -> [(name: String, description: String)] {
        entries.filter { $0.name.hasPrefix(prefix) }
    }
}
