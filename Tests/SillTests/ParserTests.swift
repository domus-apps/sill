import Foundation
import Testing
@testable import Sill

// MARK: - Tokenizer

@Test func tokenizerSplitsWordsAndTracksTypedLength() {
    let tokens = Tokenizer.tokenize("git commit -m 'hello world' ")
    #expect(tokens.map(\.text) == ["git", "commit", "-m", "hello world", ""])
    #expect(tokens[3].typedLength == 13)  // quotes count as typed characters
}

@Test func tokenizerHandlesEscapesAndDoubleQuotes() {
    let tokens = Tokenizer.tokenize(#"cp My\ File "a \"b\" c""#)
    #expect(tokens.map(\.text) == ["cp", "My File", "a \"b\" c"])
    #expect(tokens[1].typedLength == 8)
}

@Test func tokenizerEmitsSeparators() {
    let tokens = Tokenizer.tokenize("ls -la | grep foo && git ch")
    #expect(tokens.filter(\.isSeparator).map(\.text) == ["|", "&&"])
    #expect(tokens.last?.text == "ch")
}

@Test func tokenizerMarksAFreshWordAfterTrailingSpace() {
    #expect(Tokenizer.tokenize("git ").last == Token(text: "", typedLength: 0))
    #expect(Tokenizer.tokenize("git").last == Token(text: "git", typedLength: 3))
}

// MARK: - Parser, against a small inline spec

private let miniSpec = """
var __sillSpec = { default: {
  name: "git",
  description: "Version control",
  subcommands: [
    { name: "checkout", description: "Switch branches",
      options: [{ name: "-b", description: "New branch", args: { name: "branch" } }],
      args: { name: "branch", suggestions: ["main", "develop"] } },
    { name: ["cherry-pick", "pick"], description: "Apply existing commits" },
    { name: "commit", description: "Record changes",
      options: [
        { name: ["-m", "--message"], description: "Commit message", args: { name: "message" } },
        { name: "--amend", description: "Amend previous commit" }
      ] },
    { name: "secret", hidden: true, description: "Hidden helper" },
    { name: "add", description: "Stage files", args: { name: "pathspec", template: "filepaths", isVariadic: true } }
  ],
  options: [{ name: ["-C"], description: "Run as if started in path", args: { name: "path" } }]
} };
"""

private func makeParser() -> CompletionParser {
    let engine = SpecEngine()
    let node = engine.evaluate(miniSpec)
    #expect(node != nil)
    return CompletionParser(engine: SpyEngine(engine: engine, root: node!))
}

/* SpecEngine loads specs from disk by command name; tests hand the parser
   an inline spec through the same protocol instead. */
struct SpyEngine: SpecProviding {
    let engine: SpecEngine  // owns the JSContext the root lives in
    let root: SpecNode
    func spec(for command: String) -> SpecNode? {
        command == "git" ? root : nil
    }
}

@Test func suggestsSubcommandsByPrefix() {
    let result = makeParser().complete(buffer: "git ch", cursor: 6)
    #expect(result.suggestions.map(\.display) == ["checkout", "cherry-pick"])
    #expect(result.suggestions[0].insertText == "checkout")
    #expect(result.suggestions[0].deleteCount == 2)
    #expect(result.suggestions[0].kind == .subcommand)
}

@Test func emptyPartialShowsAllVisibleSubcommands() {
    let result = makeParser().complete(buffer: "git ", cursor: 4)
    let names = result.suggestions.map(\.display)
    #expect(names.contains("checkout"))
    #expect(names.contains("commit"))
    #expect(!names.contains("secret"))  // hidden
}

@Test func aliasedSubcommandsShowTheAliasThatMatches() {
    // Nothing typed: the canonical (longest) alias is listed, not "pick".
    #expect(makeParser().complete(buffer: "git ", cursor: 4).suggestions
        .map(\.display).contains("cherry-pick"))
    #expect(!makeParser().complete(buffer: "git ", cursor: 4).suggestions
        .map(\.display).contains("pick"))
    // Typing the short alias surfaces and completes it.
    let short = makeParser().complete(buffer: "git pi", cursor: 6).suggestions
    #expect(short.map(\.display) == ["pick"])
    #expect(short.first?.insertText == "pick")
    // When several aliases match, the canonical (longest) one is shown.
    #expect(CompletionParser.preferredName(["i", "install"], matching: "i") == "install")
    #expect(CompletionParser.preferredName(["a", "add"], matching: "") == "add")
    // The other aliases ride along for display.
    let cherry = makeParser().complete(buffer: "git ch", cursor: 6).suggestions
        .first { $0.display == "cherry-pick" }
    #expect(cherry?.aliases == ["pick"])
}

@Test func optionAliasesCollapseIntoOneRow() {
    let result = makeParser().complete(buffer: "git commit -", cursor: 12)
    let message = result.suggestions.first { $0.display == "--message" }
    #expect(message?.aliases == ["-m"])
    #expect(!result.suggestions.contains { $0.display == "-m" })
    // Typing the short form still completes it, long form shown as alias.
    let short = makeParser().complete(buffer: "git commit -m", cursor: 13).suggestions
    #expect(short.map(\.display) == ["-m"])
    #expect(short.first?.aliases == ["--message"])
}

@Test func aliasedSubcommandDescends() {
    let result = makeParser().complete(buffer: "git pick ", cursor: 9)
    #expect(result.suggestions.isEmpty)  // cherry-pick has no subcommands/args
}

@Test func dashPartialSuggestsOptions() {
    let result = makeParser().complete(buffer: "git commit --a", cursor: 14)
    #expect(result.suggestions.map(\.display) == ["--amend"])
    #expect(result.suggestions[0].kind == .option)
}

@Test func optionArgConsumesNextToken() {
    // "-m <message>" — after the message token, options are suggested again.
    let result = makeParser().complete(buffer: "git commit -m 'fix' --a", cursor: 23)
    #expect(result.suggestions.map(\.display) == ["--amend"])
}

@Test func pendingOptionArgSuppressesOtherSuggestions() {
    let result = makeParser().complete(buffer: "git commit -m ", cursor: 14)
    #expect(result.suggestions.isEmpty)
    #expect(result.pendingArg == nil)  // message arg has no template/generator
}

@Test func staticArgSuggestionsAppear() {
    let result = makeParser().complete(buffer: "git checkout ma", cursor: 15)
    #expect(result.suggestions.map(\.display) == ["main"])
    #expect(result.suggestions[0].kind == .argument)
}

@Test func subcommandsOutrankArgsButBothAppear() {
    let result = makeParser().complete(buffer: "git checkout ", cursor: 13)
    let names = result.suggestions.map(\.display)
    #expect(names.contains("main"))
    #expect(names.contains("develop"))
}

@Test func filepathTemplateSurfacesAsPendingArg() {
    let result = makeParser().complete(buffer: "git add sr", cursor: 10)
    #expect(result.pendingArg != nil)
    #expect(result.pendingArg?.node.templates == ["filepaths"])
    #expect(result.pendingArg?.partial.text == "sr")
}

@Test func pipelineCompletesTheRightmostCommand() {
    let result = makeParser().complete(buffer: "ls -la | git ch", cursor: 15)
    #expect(result.suggestions.map(\.display) == ["checkout", "cherry-pick"])
}

@Test func wrappersAndAssignmentsAreStripped() {
    let result = makeParser().complete(buffer: "FOO=bar sudo git ch", cursor: 19)
    #expect(result.suggestions.map(\.display) == ["checkout", "cherry-pick"])
}

@Test func unknownCommandYieldsNothing() {
    let result = makeParser().complete(buffer: "unknowncmd ch", cursor: 13)
    #expect(result.suggestions.isEmpty)
}

@Test func bareCommandWordYieldsNothing() {
    // Still typing the command itself — v1 doesn't complete command names.
    let result = makeParser().complete(buffer: "gi", cursor: 2)
    #expect(result.suggestions.isEmpty)
}

@Test func quotedPartialDeleteCountIncludesQuotes() {
    let result = makeParser().complete(buffer: "git checkout 'ma", cursor: 16)
    #expect(result.suggestions.first?.display == "main")
    #expect(result.suggestions.first?.deleteCount == 3)
}


// MARK: - Recency

@Test func recentlyPickedSuggestionsComeFirstAmongEqualMatches() {
    let engine = SpecEngine()
    let node = engine.evaluate(miniSpec)!
    let recency = RecencyStore(defaults: nil)
    recency.record(command: "git", display: "cherry-pick")
    let parser = CompletionParser(engine: SpyEngine(engine: engine, root: node), recency: recency)

    // Both are exact-prefix matches for "ch"; the picked one leads.
    #expect(parser.complete(buffer: "git ch", cursor: 6).suggestions.map(\.display)
        == ["cherry-pick", "checkout"])
    // But recency never beats match quality: "chec" only matches checkout.
    #expect(parser.complete(buffer: "git chec", cursor: 8).suggestions.map(\.display)
        == ["checkout"])
}

@Test func recencyStoreOrdersMostRecentFirstAndKeepsOthersStable() {
    let recency = RecencyStore(defaults: nil)
    let items = ["a", "b", "c", "d"].map {
        Suggestion(display: $0, insertText: $0, deleteCount: 0, detail: "", kind: .argument)
    }
    recency.record(command: "cd", display: "c")
    Thread.sleep(forTimeInterval: 0.01)
    recency.record(command: "cd", display: "b")
    #expect(recency.sorted(items, command: "cd").map(\.display) == ["b", "c", "a", "d"])
    // Scoped per command: another command's picks don't leak.
    #expect(recency.sorted(items, command: "ls").map(\.display) == ["a", "b", "c", "d"])
}

// MARK: - A finished word offers nothing

@Test func aFullyTypedSuggestionInsertsNothing() {
    let parser = makeParser()

    // "git checkout" — the only match is the word already typed.
    let done = parser.complete(buffer: "git checkout", cursor: 12)
    #expect(done.suggestions.map(\.display) == ["checkout"])
    #expect(done.suggestions[0].insertsNothing(before: "git checkout"))

    // One character short, it still has something to insert.
    let partial = parser.complete(buffer: "git checkou", cursor: 11)
    #expect(partial.suggestions[0].insertsNothing(before: "git checkou") == false)

    // An alias typed in full still shows the canonical name beside it and
    // inserts that — not a no-op.
    let alias = parser.complete(buffer: "git pick", cursor: 8)
    #expect(alias.suggestions[0].display == "pick")
    #expect(alias.suggestions[0].aliases == ["cherry-pick"])
    #expect(alias.suggestions[0].insertsNothing(before: "git pick"))
}
