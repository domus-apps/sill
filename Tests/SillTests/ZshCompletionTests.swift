import Foundation
import Testing
@testable import Sill

/// The shape of mole's _mole: an array for _describe, then `case` on the
/// subcommand with _arguments specs per branch.
private let moleCompletion = #"""
#compdef mole mo

_mole() {
    local -a subcommands
    subcommands=(
        'clean:Free up disk space'
        'analyze:Explore disk usage'
        'completion:Setup shell tab completion'
        'touchid:Configure Touch ID for sudo'
    )
    if (( CURRENT == 2 )); then
        _describe 'subcommand' subcommands
        return
    fi
    case "$words[2]" in
        clean)
            _arguments \
                '--dry-run[Preview cleanup without making changes]' \
                '-n[Preview cleanup without making changes]' \
                '--external[Clean OS metadata from an external volume]:path:_files -/' \
                '(-h --help)'{-h,--help}'[Show help]'
            ;;
        analyze|analyse)
            _arguments \
                '--json[Output analysis as JSON]' \
                '*:path:_files'
            ;;
        completion)
            _arguments '1:shell:(bash zsh fish)'
            ;;
        *)
            _describe 'subcommand' subcommands
            ;;
    esac
}

compdef _mole mole mo
"""#

private struct OneSpec: SpecProviding {
    let node: SpecNode
    let name: String
    func spec(for command: String) -> SpecNode? { command == name ? node : nil }
}

private func parser(for object: [String: Any], name: String) throws -> (CompletionParser, SpecEngine) {
    let data = try JSONSerialization.data(withJSONObject: object)
    let engine = SpecEngine()
    let node = try #require(engine.evaluateJSON(String(decoding: data, as: UTF8.self)))
    return (CompletionParser(engine: OneSpec(node: node, name: name)), engine)
}

@Test func moleStyleFileCompletesSubcommandsOptionsAndValues() throws {
    let object = try #require(ZshCompletion.spec(moleCompletion, command: "mo", fileName: "_mole"))
    let (parser, engine) = try parser(for: object, name: "mo")
    _ = engine

    let top = parser.complete(buffer: "mo ", cursor: 3)
    #expect(top.suggestions.map(\.display) == ["analyze", "clean", "completion", "touchid"])
    #expect(top.suggestions.first { $0.display == "clean" }?.detail == "Free up disk space")
    #expect(top.unexploredPath == nil)   // read whole: nothing to run later

    // -n and --dry-run share a description: one option, two names.
    let clean = parser.complete(buffer: "mo clean --", cursor: 11)
    #expect(clean.suggestions.map(\.display) == ["--dry-run", "--external", "--help"])
    #expect(clean.suggestions[0].detail == "Preview cleanup without making changes")

    // The second pattern of `analyze|analyse)` is an alias.
    let analyse = parser.complete(buffer: "mo analyse --", cursor: 13)
    #expect(analyse.suggestions.map(\.display) == ["--json"])

    let shells = parser.complete(buffer: "mo completion ", cursor: 14)
    #expect(shells.suggestions.map(\.display) == ["bash", "fish", "zsh"])

    // The catch-all branch adds nothing of its own.
    #expect((object["subcommands"] as? [[String: Any]])?.count == 4)
}

@Test func optionValuesAndFoldersComeFromActions() throws {
    let object = try #require(ZshCompletion.spec(moleCompletion, command: "mo", fileName: "_mole"))
    let clean = try #require((object["subcommands"] as? [[String: Any]])?.first {
        ($0["name"] as? [String])?.first == "clean"
    })
    let external = try #require((clean["options"] as? [[String: Any]])?.first {
        ($0["name"] as? [String]) == ["--external"]
    })
    #expect((external["args"] as? [String: Any])?["template"] as? String == "folders")
    let analyze = try #require((object["subcommands"] as? [[String: Any]])?.first {
        ($0["name"] as? [String])?.first == "analyze"
    })
    #expect(analyze["name"] as? [String] == ["analyze", "analyse"])
    let path = try #require((analyze["args"] as? [[String: Any]])?.first)
    #expect(path["template"] as? String == "filepaths")
    #expect(path["isVariadic"] as? Bool == true)
}

/// The other common hand-written shape: _arguments -C with states, and a
/// nested `case $line[1]` for each subcommand.
private let stateCompletion = #"""
#compdef tool

_tool() {
    local curcontext="$curcontext" state line
    local -a commands colors
    commands=('push:Upload changes' 'pull:Fetch changes')
    colors=('auto:Pick for me' 'never:No color')
    _arguments -C \
        '--verbose[Be loud]' \
        '--color=[When to color]:when:->colors' \
        '--style=[Output style]:style:((plain\:"No decoration" fancy\:"Boxes and color"))' \
        '1: :->cmds' \
        '*:: :->args' && ret=0
    case $state in
        cmds)
            _describe -t commands 'tool command' commands
            ;;
        colors)
            _describe 'when' colors
            ;;
        args)
            case $line[1] in
                (push)
                    _arguments '--force[Overwrite the remote]'
                    ;;
            esac
            ;;
    esac
}

_tool "$@"
"""#

@Test func statesAndNestedLineCasesPlaceEachCall() throws {
    let object = try #require(ZshCompletion.spec(stateCompletion, command: "tool", fileName: "_tool"))
    let subcommands = try #require(object["subcommands"] as? [[String: Any]])
    // The colors state belongs to --color's value, not to the subcommands.
    #expect(subcommands.map { ($0["name"] as? [String])?.first } == ["push", "pull"])
    let push = subcommands[0]
    #expect((push["options"] as? [[String: Any]])?.map { $0["name"] as? [String] } == [["--force"]])
    let options = try #require(object["options"] as? [[String: Any]])
    #expect(options.map { $0["name"] as? [String] } == [["--verbose"], ["--color"], ["--style"]])
    #expect(options[1]["args"] != nil)   // takes a value
    let style = try #require((options[2]["args"] as? [String: Any])?["suggestions"] as? [[String: Any]])
    #expect(style.map { $0["name"] as? String } == ["plain", "fancy"])
    #expect(style.map { $0["description"] as? String } == ["No decoration", "Boxes and color"])
}

@Test func helperFunctionsNamedByAnActionAreFollowed() throws {
    let source = #"""
    #compdef runner
    _runner() {
        _arguments ':: :_runner_commands' '--quiet[Say less]'
    }
    (( $+functions[_runner_commands] )) ||
    _runner_commands() {
        local commands; commands=(
            'start:Start the service'
            'stop:Stop the service'
        )
        _describe -t commands 'runner commands' commands "$@"
    }
    """#
    let object = try #require(ZshCompletion.spec(source, command: "runner", fileName: "_runner"))
    #expect((object["subcommands"] as? [[String: Any]])?.map { $0["description"] as? String }
            == ["Start the service", "Stop the service"])
    #expect((object["options"] as? [[String: Any]])?.count == 1)
}

@Test func whatOnlyRunningCouldTellIsLeftOut() {
    // cobra's file asks the program itself.
    let cobra = #"""
    #compdef gizmo
    __gizmo_complete() {
        local out
        out=$(${words[1]} __complete "${words[@]:1}" 2>/dev/null)
        compadd -- ${(f)out}
    }
    compdef __gizmo_complete gizmo
    """#
    #expect(ZshCompletion.spec(cobra, command: "gizmo", fileName: "_gizmo") == nil)
    // A list built at completion time can't be read either.
    let computed = #"""
    #compdef lister
    local -a things
    things=( ${(f)"$(lister --list)"} )
    _describe 'thing' things
    """#
    #expect(ZshCompletion.spec(computed, command: "lister", fileName: "_lister") == nil)
}

@Test func compdefLineNamesCommands() {
    #expect(ZshCompletion.compdefNames("#compdef mole mo") == ["mole", "mo"])
    #expect(ZshCompletion.compdefNames("#compdef -N foo bar=baz -p 'qux-*'") == ["foo", "bar"])
    #expect(ZshCompletion.compdefNames("# compdef mole").isEmpty)
}

@Test func completionFileIsFoundBesideTheBin() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("sill-zsh-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let functions = root.appendingPathComponent("share/zsh/site-functions")
    let keg = root.appendingPathComponent("Cellar/mole/1.0/libexec")
    for folder in [functions, keg, root.appendingPathComponent("bin")] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    try Data("#!/bin/bash\n".utf8).write(to: keg.appendingPathComponent("mole"))
    for name in ["mo", "mole"] {
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("bin/\(name)").path,
            withDestinationPath: "../Cellar/mole/1.0/libexec/mole")
    }
    try Data(moleCompletion.utf8).write(to: functions.appendingPathComponent("_mole"))
    try Data("#compdef other\n".utf8).write(to: functions.appendingPathComponent("_other"))

    let mo = ZshCompletion.file(for: "mo", executable: root.appendingPathComponent("bin/mo"))
    #expect(mo?.lastPathComponent == "_mole")   // by its #compdef line
    let mole = ZshCompletion.file(for: "mole", executable: root.appendingPathComponent("bin/mole"))
    #expect(mole?.lastPathComponent == "_mole")
    #expect(ZshCompletion.file(for: "absent", executable: root.appendingPathComponent("bin/absent")) == nil)
}

@Test func braceExpansionKeepsQuotedBracesLiteral() {
    let words = ZshCompletion.tokens(#"'(-h --help)'{-h,--help}'[Show {help}]' plain{a,b}c"#)
        .compactMap { token -> [String]? in
            if case .word(let word) = token { return word.expanded }
            return nil
        }
    #expect(words == [
        ["(-h --help)-h[Show {help}]", "(-h --help)--help[Show {help}]"],
        ["plainac", "plainbc"],
    ])
}

@Test func specsKeptInAnArrayAreRead() throws {
    // ripgrep's shape, and clap's flags passed the same way.
    let source = #"""
    #compdef finder
    _finder() {
      local -a args _arguments_options
      _arguments_options=(-s -S -C)
      args=(
        '(-i --ignore-case)'{-i,--ignore-case}'[Search case-insensitively]'
        '--type=[Only search files of TYPE]:type:(rust swift)'
      )
      args+=( '*:file:_files' )
      _arguments "${_arguments_options[@]}" : $args
    }
    """#
    let object = try #require(ZshCompletion.spec(source, command: "finder", fileName: "_finder"))
    let options = try #require(object["options"] as? [[String: Any]])
    #expect(options.map { $0["name"] as? [String] } == [["-i", "--ignore-case"], ["--type"]])
    #expect((object["args"] as? [[String: Any]])?.first?["template"] as? String == "filepaths")
}
