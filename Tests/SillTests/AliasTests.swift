import Foundation
import Testing
@testable import Sill

private struct AliasTestCatalog: CommandCatalogProviding {
    func commands(matching prefix: String, searchPath: String) -> [(name: String, description: String)] {
        [("git", "Version control")].filter { $0.0.hasPrefix(prefix) }
    }
}

@Test func shellAliasesAreSuggestedWithTheirDefinitionsAndRespectThePreference() {
    var parser = makeParser()
    parser.commands = AliasTestCatalog()
    parser.shellAliases = ["g": "git", "gco": "git checkout", "git": "git --no-pager", "deploy": "echo ok && true"]
    let rows = parser.complete(buffer: "g", cursor: 1).suggestions
    #expect(rows.filter { $0.display == "git" }.count == 1)
    #expect(rows.first?.display == "g")
    #expect(rows.first?.insertText == "g")
    #expect(rows.first?.detail == "→ git")
    #expect(rows.first?.deleteCount == 1)
    #expect(parser.complete(buffer: "dep", cursor: 3).suggestions.first?.display == "deploy")
    parser.commands = nil
    #expect(parser.complete(buffer: "g", cursor: 1).suggestions.isEmpty)
    #expect(parser.complete(buffer: "g ch", cursor: 4).suggestions.contains { $0.display == "checkout" })
}

@Test func shellAliasesExpandForArgumentsWithoutChangingTheReplacementRange() {
    var parser = makeParser()
    parser.shellAliases = ["g": "git", "gco": "g checkout", "gc": "git commit -m 'fixed message'",
                           "git": "git --no-pager"]
    let branch = parser.complete(buffer: "gco ma", cursor: 6)
    #expect(branch.suggestions.first?.display == "main")
    #expect(branch.suggestions.first?.deleteCount == 2)
    #expect(branch.commandTokens == ["git", "--no-pager", "checkout", "ma"])
    #expect(branch.path == ["git", "checkout"])
    let option = parser.complete(buffer: "gc --a", cursor: 6)
    #expect(option.suggestions.first?.display == "--amend")
    #expect(option.commandTokens == ["git", "--no-pager", "commit", "-m", "fixed message", "--a"])
    let quoted = "echo x | gco 'ma"
    #expect(parser.complete(buffer: quoted, cursor: quoted.count).suggestions.first?.deleteCount == 3)
}

@Test func shellAliasExpansionRespectsQuotesWrappersAndCycles() {
    var parser = makeParser()
    parser.shellAliases = ["g": "git", "a": "b", "b": "a", "run": "git checkout && echo done",
                           "sub": "git $(echo checkout)"]
    for buffer in ["\\g ch", "'g' ch", "sudo g ch", "command g ch", "a ch", "run ma", "sub ma"] {
        #expect(parser.complete(buffer: buffer, cursor: buffer.count).suggestions.isEmpty)
    }
    for buffer in ["X=1 g ch", "echo x && g ch"] {
        #expect(parser.complete(buffer: buffer, cursor: buffer.count).suggestions.contains { $0.display == "checkout" })
    }
    for buffer in ["a ch", "run ma", "sub ma"] {
        #expect(parser.complete(buffer: buffer, cursor: buffer.count).unknownCommand == nil)
    }
}

@Test func gitAliasesAreListedAndExpandThroughShellAliases() {
    var parser = makeParser()
    parser.shellAliases = ["g": "git", "gco": "git co"]
    parser.gitAliases = ["co": "checkout", "cob": "co -b", "cm": "commit -m 'fixed message'",
                         "checkout": "commit", "publish": "!echo hello"]
    let rows = parser.complete(buffer: "g c", cursor: 3).suggestions
    #expect(rows.contains { $0.display == "co" && $0.insertText == "co" && $0.detail == "→ checkout" })
    #expect(rows.filter { $0.display == "checkout" }.count == 1)
    for buffer in ["git co ma", "gco ma", "git 'co' ma"] {
        let result = parser.complete(buffer: buffer, cursor: buffer.count)
        #expect(result.suggestions.first?.display == "main")
        #expect(result.suggestions.first?.deleteCount == 2)
        #expect(result.commandTokens == ["git", "checkout", "ma"])
    }
    #expect(parser.complete(buffer: "git cm --a", cursor: 10).suggestions.first?.display == "--amend")
    #expect(parser.complete(buffer: "git cob ", cursor: 8).commandTokens == ["git", "checkout", "-b", ""])
    #expect(parser.complete(buffer: "git publish ", cursor: 12).suggestions.isEmpty)
    #expect(parser.complete(buffer: "git p", cursor: 5).suggestions.contains { $0.display == "publish" })
    // Git's built-in commands take precedence over config aliases.
    #expect(parser.complete(buffer: "git checkout ma", cursor: 15).suggestions.first?.display == "main")
    #expect(!parser.complete(buffer: "git checkout c", cursor: 14).suggestions.contains { $0.display == "co" })
    parser.gitAliases = ["a": "b", "b": "a"]
    #expect(parser.complete(buffer: "git a ", cursor: 6).suggestions.isEmpty)
}

@Test func aliasedCommandsKeepFileAndGeneratorContext() {
    var parser = makeParser()
    parser.shellAliases = ["ga": "git add"]
    let result = parser.complete(buffer: "ga src/fi", cursor: 9)
    #expect(result.commandTokens == ["git", "add", "src/fi"])
    #expect(result.pendingArg?.node.templates == ["filepaths"])
    #expect(result.pendingArg?.partial == Token(text: "src/fi", typedLength: 6))
}

@Test func gitAliasRecordsKeepMultilineValuesAndTheLastDefinition() {
    let data = Data("alias.co\ncheckout\0alias.publish\n!f() {\n echo hi;\n}; f\0alias.co\nswitch\0".utf8)
    #expect(GitAliasStore.decode(data) == ["co": "switch", "publish": "!f() {\n echo hi;\n}; f"])
}

@Test func aliasProtocolAcceptsSnapshotsAndRejectsMalformedValues() {
    let message = ShellMessage.decode(Data(#"{"t":"aliases","sid":"s","values":{"g":"git","cm":"git commit -m \"hello\""}}"#.utf8))
    #expect(message == .aliases(sid: "s", values: ["g": "git", "cm": "git commit -m \"hello\""]))
    #expect(message?.sid == "s")
    #expect(ShellMessage.decode(Data(#"{"t":"aliases","sid":"s","values":{}}"#.utf8)) == .aliases(sid: "s", values: [:]))
    #expect(ShellMessage.decode(Data(#"{"t":"aliases","sid":"s","values":{"g":1}}"#.utf8)) == nil)
}

@Test func gitAliasReadsRespectIncludesRepositoryOverridesAndChanges() throws {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: directory) }
    let repo = directory.appendingPathComponent("repo")
    let other = directory.appendingPathComponent("other")
    try fm.createDirectory(at: repo, withIntermediateDirectories: true)
    try fm.createDirectory(at: other, withIntermediateDirectories: true)
    let environment = ["HOME": directory.path, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1",
                       "XDG_CONFIG_HOME": directory.appendingPathComponent("xdg").path]
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["init", "--quiet", repo.path]
    process.environment = environment
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    // Match the unique fixture suffix: Foundation and Git can spell macOS's
    // temporary root differently (/var versus /private/var).
    try "[alias]\n co = checkout\n global = status\n[includeIf \"gitdir:**/\(directory.lastPathComponent)/repo/.git\"]\n path = conditional\n"
        .write(to: directory.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
    try "[alias]\n conditional = log\n".write(to: directory.appendingPathComponent("conditional"), atomically: true, encoding: .utf8)
    let local = repo.appendingPathComponent(".git/config")
    try "[alias]\n co = commit\n local = diff\n".write(to: local, atomically: true, encoding: .utf8)
    let context = try #require(GitAliasStore.Context(cwd: repo.path, tokens: Tokenizer.tokenize("git ")))
    #expect(GitAliasStore.read(context, environment: environment) == ["co": "commit", "global": "status", "local": "diff", "conditional": "log"])
    let outside = try #require(GitAliasStore.Context(cwd: other.path, tokens: Tokenizer.tokenize("git ")))
    #expect(GitAliasStore.read(outside, environment: environment) == ["co": "checkout", "global": "status"])
    try "[alias]\n co = switch\n".write(to: local, atomically: true, encoding: .utf8)
    #expect(GitAliasStore.read(context, environment: environment)["co"] == "switch")
    #expect(GitAliasStore.read(context, environment: environment)["local"] == nil)
    let flags = try #require(GitAliasStore.Context(cwd: directory.path,
        tokens: Tokenizer.tokenize("git --no-pager -C repo -c alias.co=checkout ")))
    #expect(GitAliasStore.read(flags, environment: environment)["co"] == "checkout")
}

@Test func zshAliasSnapshotsEscapeValuesAndSendChangesAndRemovals() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let script = try String(contentsOf: root.appendingPathComponent("ShellIntegration/sill.zsh"), encoding: .utf8)
    let start = try #require(script.range(of: "_sill_escape_reply() {"))
    let end = try #require(script.range(of: "_sill_connect() {"))
    let functions = String(script[start.lowerBound..<end.lowerBound])
    let harness = functions + #"""

    zmodload zsh/parameter
    unalias -m '*'
    typeset -g _sill_fd=1 _sill_sid=test _sill_last_aliases=''
    _sill_send() { print -r -- "$1" }
    alias g=git
    alias cm=$'git commit -m "hello"\n# next\\line'
    alias -g GLOBAL='| cat'
    alias -s txt=cat
    _sill_send_aliases
    _sill_send_aliases
    alias g='git --no-pager'
    _sill_send_aliases
    unalias g cm
    _sill_send_aliases
    """#
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-dfc", harness]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    var framer = LineFramer()
    let messages = framer.consume(data).compactMap(ShellMessage.decode)
    #expect(messages == [
        .aliases(sid: "test", values: ["g": "git", "cm": "git commit -m \"hello\"\n# next\\line"]),
        .aliases(sid: "test", values: ["g": "git --no-pager", "cm": "git commit -m \"hello\"\n# next\\line"]),
        .aliases(sid: "test", values: [:]),
    ])
}
