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

let miniSpec = """
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

func makeParser() -> CompletionParser {
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
    // But recency never beats match quality: "chec" is a prefix of checkout
    // and only a loose subsequence of the picked cherry-pick.
    #expect(parser.complete(buffer: "git chec", cursor: 8).suggestions.map(\.display)
        == ["checkout", "cherry-pick"])
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

// MARK: - The first word: command names

private struct FixedCatalog: CommandCatalogProviding {
    var entries: [(name: String, description: String)]
    func commands(matching prefix: String, searchPath: String) -> [(name: String, description: String)] {
        entries.filter { $0.name.hasPrefix(prefix) }
    }
}

@Test func firstWordOffersCommandNames() {
    let catalog = FixedCatalog(entries: [
        ("git", "The stupid content tracker"), ("gh", "GitHub CLI"), ("bun", "Bun runtime"),
    ])
    let recency = RecencyStore(defaults: nil)
    var parser = makeParser()
    parser.commands = catalog
    parser.recency = recency

    let g = parser.complete(buffer: "g", cursor: 1)
    #expect(g.suggestions.map(\.display) == ["gh", "git"])   // alphabetical until used
    #expect(g.suggestions[1].detail == "The stupid content tracker")
    #expect(g.suggestions[1].kind == .command)
    #expect(g.suggestions[1].insertText == "git")
    #expect(g.suggestions[1].deleteCount == 1)

    // Having completed something inside git before makes git the likelier command.
    recency.record(command: "git", display: "checkout")
    #expect(parser.complete(buffer: "g", cursor: 1).suggestions.map(\.display) == ["git", "gh"])

    // Wrappers are stepped over; an empty prompt, paths, flags and assignments stay quiet.
    #expect(parser.complete(buffer: "sudo g", cursor: 6).suggestions.map(\.display) == ["git", "gh"])
    #expect(parser.complete(buffer: "", cursor: 0).suggestions.isEmpty)
    #expect(parser.complete(buffer: "./g", cursor: 3).suggestions.isEmpty)
    #expect(parser.complete(buffer: "-g", cursor: 2).suggestions.isEmpty)
    #expect(parser.complete(buffer: "FOO=g", cursor: 5).suggestions.isEmpty)
}

@Test func catalogKeepsOnlyRunnableDefinitions() throws {
    // An index with two specs; only the one on PATH (ls) or a builtin (cd) qualifies.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sill-catalog-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let index: [String: Any] = [
        "version": "t", "files": ["ls.js", "cd.js", "frobnicate.js", "aws/s3.js"],
        "descriptions": ["ls": "List directory contents", "cd": "Change directory"],
    ]
    try JSONSerialization.data(withJSONObject: index).write(to: dir.appendingPathComponent("index.json"))

    let catalog = CommandCatalog(specDirectories: [dir], derived: nil)
    let names = catalog.commands(matching: "", searchPath: "/bin").map(\.name)
    #expect(names.isEmpty)   // nothing typed, nothing offered
    let l = catalog.commands(matching: "l", searchPath: "/bin")
    #expect(l.map(\.name) == ["ls"])
    #expect(l[0].description == "List directory contents")
    #expect(catalog.commands(matching: "c", searchPath: "/bin").map(\.name) == ["cd"])
    #expect(catalog.commands(matching: "f", searchPath: "/bin").isEmpty)   // defined, not installed
    #expect(catalog.commands(matching: "s", searchPath: "/bin").isEmpty)   // aws/s3 is not a command
    #expect(CommandCatalog.scan("/bin").contains("ls"))
}

// MARK: - Files and folders from the template resolver

@Test func folderCompletionShowsButDoesNotTypeTheSlash() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("sill-template-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("src"),
                                            withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent("setup.sh"))
    defer { try? FileManager.default.removeItem(at: root) }

    let partial = Token(text: "s", typedLength: 1)
    let all = TemplateResolver.suggestions(templates: ["filepaths"], partial: partial, cwd: root.path)
    let folder = try #require(all.first { $0.kind == .folder })
    #expect(folder.display == "src/")        // the slash marks it as a folder…
    #expect(folder.insertText == "src")      // …but is left for the user to type
    let file = try #require(all.first { $0.kind == .file })
    #expect(file.display == "setup.sh")
    #expect(file.insertText == "setup.sh")   // and no trailing space either

    // A path prefix is kept in the insertion, still without the slash.
    let nested = TemplateResolver.suggestions(
        templates: ["folders"], partial: Token(text: "./s", typedLength: 3), cwd: root.path)
    #expect(nested.map(\.insertText) == ["./src"])
}

@Test func generatorFolderNamesLoseTheirSlashOnInsertion() {
    #expect(GeneratorRunner.insertion(for: "Sources/") == "Sources")
    #expect(GeneratorRunner.insertion(for: "main") == "main")
    #expect(GeneratorRunner.insertion(for: "My Dir/") == "My\\ Dir")
}

@Test func anExactAliasOutranksPlainPrefixMatches() {
    // "i" is an alias of install and merely a prefix of info and init. (The
    // test engine answers to "git" only, so the spec is mounted under git.)
    let engine = SpecEngine()
    let spec = """
    var __sillSpec = { default: { name: "git", subcommands: [
      { name: "info", description: "Show package info" },
      { name: "init", description: "Create a package.json" },
      { name: ["install", "i", "add"], description: "Install a package" }
    ] } };
    """
    let node = engine.evaluate(spec)!
    let parser = CompletionParser(engine: SpyEngine(engine: engine, root: node))
    let result = parser.complete(buffer: "git i", cursor: 5)
    #expect(result.suggestions.map(\.display) == ["install", "info", "init"])
    #expect(result.suggestions.first?.insertText == "install")
    // Typing more than the alias goes back to ordinary ranking.
    #expect(parser.complete(buffer: "git in", cursor: 6).suggestions.map(\.display) == ["info", "init", "install"])
}

// MARK: - Overlays fill what a spec is missing

private struct FixedOverlays: OverlayProviding {
    var levels: [String: OverlayLevel]
    func overlay(for path: [String]) -> OverlayLevel? { levels[path.joined(separator: " ")] }
}

@Test func overlayAddsWhatTheSpecLacksWithoutDuplicatingIt() {
    var parser = makeParser()
    parser.overlays = FixedOverlays(levels: [
        "git": OverlayLevel(
            subcommands: [.init(names: ["switch"], description: "Switch branches"),
                          .init(names: ["commit"], description: "Duplicate of the spec's own")],
            options: [.init(names: ["--paginate", "-P"], description: "Page the output")]),
    ])
    // The spec's rows keep their own descriptions; only "switch" is new.
    let all = parser.complete(buffer: "git ", cursor: 4)
    #expect(all.suggestions.filter { $0.display == "commit" }.count == 1)
    #expect(all.suggestions.first { $0.display == "commit" }?.detail == "Record changes")
    #expect(all.suggestions.contains { $0.display == "switch" && $0.detail == "Switch branches" })
    #expect(all.path == ["git"])

    #expect(parser.complete(buffer: "git sw", cursor: 6).suggestions.map(\.display) == ["switch"])
    let option = parser.complete(buffer: "git --pa", cursor: 8).suggestions
    #expect(option.map(\.display) == ["--paginate"])
    #expect(option.first?.aliases == ["-P"])

    // A level with no overlay is untouched, and the path names the level.
    let deeper = parser.complete(buffer: "git checkout -", cursor: 14)
    #expect(deeper.path == ["git", "checkout"])
    #expect(deeper.suggestions.map(\.display) == ["-b"])
}

@Test func overlayLevelDecodesTheStoredShape() {
    let level = OverlayLevel([
        "subcommands": [["name": ["switch"], "description": "Switch branches"], ["name": "token"]],
        "options": [["name": ["-P", "--paginate"], "description": "Page"]],
    ] as [String: Any])
    #expect(level.subcommands.map(\.names) == [["switch"], ["token"]])
    #expect(level.subcommands[1].description == "")
    #expect(level.options.first?.names == ["-P", "--paginate"])
}

@Test func parentFolderIsOfferedAndMatchesWhatWasTyped() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("sill-parent-\(UUID().uuidString)")
    let inner = root.appendingPathComponent("inner")
    try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("sibling"),
                                            withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // "cd .." — the parent is a folder like any other, and exactly what was typed.
    let dots = TemplateResolver.suggestions(
        templates: ["folders"], partial: Token(text: "..", typedLength: 2), cwd: inner.path)
    #expect(dots.map(\.display) == ["../"])
    #expect(dots[0].insertText == "..")
    #expect(dots[0].insertsNothing(before: "cd .."))

    // "cd ../" — the parent's folders are listed, with "../" itself on top so
    // Return goes up while the arrows reach "sibling/".
    let slashed = TemplateResolver.suggestions(
        templates: ["folders"], partial: Token(text: "../", typedLength: 3), cwd: inner.path)
    #expect(slashed.first?.display == "../")
    #expect(slashed.first?.insertsNothing(before: "cd ../") == true)
    #expect(slashed.map(\.display).contains("sibling/"))

    // Deeper up-paths work the same way; a plain folder's slash does not.
    let twice = TemplateResolver.suggestions(
        templates: ["folders"], partial: Token(text: "../../", typedLength: 6), cwd: inner.path)
    #expect(twice.first?.display == "../../")
    let plain = TemplateResolver.suggestions(
        templates: ["folders"], partial: Token(text: "inner/", typedLength: 6), cwd: root.path)
    #expect(!plain.contains { $0.display.hasPrefix("..") })

    // Generator listings (cd's) get the same entry, once.
    let fromGenerator = [Suggestion(display: "sibling/", insertText: "../sibling", deleteCount: 3,
                                    detail: "", kind: .folder)]
    let merged = TemplateResolver.withParentEntry(fromGenerator, partial: Token(text: "../", typedLength: 3))
    #expect(merged.map(\.display) == ["../", "sibling/"])
    #expect(TemplateResolver.withParentEntry(merged, partial: Token(text: "../", typedLength: 3)).count == 2)
}

// MARK: - Arrow keys at the ends of the list

@Test func heldArrowStopsAtTheEndWhileATapWrapsRound() {
    // No earlier press in that direction: a tap.
    #expect(CompletionController.arrowWraps(sinceLast: nil, repeatInterval: 0.083))
    // A repeat arrives at the key-repeat interval (or a little late).
    #expect(!CompletionController.arrowWraps(sinceLast: 0.083, repeatInterval: 0.083))
    #expect(!CompletionController.arrowWraps(sinceLast: 0.12, repeatInterval: 0.083))
    // Deliberate taps come well apart.
    #expect(CompletionController.arrowWraps(sinceLast: 0.3, repeatInterval: 0.083))
    // With the fastest repeat setting, even quick tapping still wraps.
    #expect(CompletionController.arrowWraps(sinceLast: 0.12, repeatInterval: 0.033))
}
