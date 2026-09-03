import Foundation
import Testing
@testable import Sill

// MARK: - HelpParser, against the common help layouts

private let commanderHelp = """
Usage: claude [options] [command] [prompt]

Claude Code - starts an interactive session by default, use -p/--print for
non-interactive output

Arguments:
  prompt                                Your prompt

Options:
  --add-dir <directories...>            Additional directories to allow tool
                                        access to
  --allowedTools, --allowed-tools <tools...>
      Comma or space-separated list of tool names to allow (e.g. "Bash(git *)
      Edit")
  -p, --print                           Print response and exit (useful for
                                        pipes)
  --autocompact <auto|tokens>           Auto-compact window size
  -v, --version                         Output the version number
  -h, --help                            Display help for command

Commands:
  mcp                                   Configure and manage MCP servers
  plugin                                Manage Claude Code plugins
  doctor                                Check the health of your installation
  help [command]                        display help for command
"""

@Test func parsesCommanderStyleHelp() {
    let spec = HelpParser.parse(commanderHelp)
    #expect(spec.description.hasPrefix("Claude Code - starts an interactive session"))
    #expect(spec.description.hasSuffix("non-interactive output"))

    let addDir = spec.options.first { $0.names == ["--add-dir"] }
    #expect(addDir?.argument == .required)
    #expect(addDir?.argumentName == "directories")
    #expect(addDir?.description == "Additional directories to allow tool access to")

    // Description on the next line, names split by comma.
    let allowed = spec.options.first { $0.names.contains("--allowed-tools") }
    #expect(allowed?.names == ["--allowedTools", "--allowed-tools"])
    #expect(allowed?.description.hasPrefix("Comma or space-separated list") == true)

    let print = spec.options.first { $0.names.contains("-p") }
    #expect(print?.names == ["-p", "--print"])
    #expect(print?.argument == nil)
    #expect(print?.description == "Print response and exit (useful for pipes)")

    #expect(spec.subcommands.map { $0.names[0] } == ["mcp", "plugin", "doctor", "help"])
    #expect(spec.subcommands[0].description == "Configure and manage MCP servers")
    // "prompt" under Arguments is not a subcommand.
    #expect(!spec.subcommands.contains { $0.names[0] == "prompt" })
}

private let cobraHelp = """
Work seamlessly with GitHub from the command line.

USAGE
  gh <command> <subcommand> [flags]

CORE COMMANDS
  auth:          Authenticate gh and git with GitHub
  browse:        Open repositories, issues, pull requests, and more in the browser
  pr:            Manage pull requests

FLAGS
  --help      Show help for command
  --version   Show gh version

Available Commands:
  completion  Generate the autocompletion script for the specified shell
  help        Help about any command

Global Flags:
  -R, --repo [HOST/]OWNER/REPO   Select another repository
  -v, --verbose                  verbose output

EXAMPLES
  $ gh issue create
"""

@Test func parsesCobraStyleHelp() {
    let spec = HelpParser.parse(cobraHelp)
    #expect(spec.description == "Work seamlessly with GitHub from the command line.")
    // gh's "auth:" rows keep their colon in the name; the plain rows don't.
    #expect(spec.subcommands.contains { $0.names[0] == "completion" })
    #expect(spec.subcommands.contains { $0.names[0] == "help" })
    #expect(!spec.subcommands.contains { $0.names[0] == "gh" })   // the usage line
    #expect(spec.options.map { $0.names[0] } == ["--help", "--version", "-R", "-v"])
    let repo = spec.options.first { $0.names[0] == "-R" }
    #expect(repo?.names == ["-R", "--repo"])
    #expect(repo?.argument == .required)
    // Nothing from EXAMPLES.
    #expect(!spec.options.contains { $0.names.contains("$") })
}

private let argparseHelp = """
usage: tool [-h] [--verbose] [--color [WHEN]] [-o OUTPUT]
            {add,remove} ...

A small tool that does a thing.

positional arguments:
  {add,remove}
    add          Add an item to the store
    remove       Remove an item from the store

options:
  -h, --help     show this help message and exit
  --verbose      Say more
  --color [WHEN]
                 Colorize the output
  -o OUTPUT, --output OUTPUT
                 Where to write
"""

@Test func parsesArgparseStyleHelp() {
    let spec = HelpParser.parse(argparseHelp)
    #expect(spec.description == "A small tool that does a thing.")
    #expect(spec.subcommands.map { $0.names[0] } == ["add", "remove"])
    #expect(spec.subcommands[1].description == "Remove an item from the store")

    let color = spec.options.first { $0.names == ["--color"] }
    #expect(color?.argument == .optional)
    #expect(color?.argumentName == "when")
    #expect(color?.description == "Colorize the output")

    let output = spec.options.first { $0.names.contains("-o") }
    #expect(output?.names == ["-o", "--output"])
    #expect(output?.argument == .required)
    #expect(output?.description == "Where to write")
}

private let goFlagHelp = """
Usage of server:
  -addr string
    \tlisten address (default ":8080")
  -v\tverbose output
  -version
    \tprint the version and exit
"""

@Test func parsesGoFlagStyleHelp() {
    let spec = HelpParser.parse(goFlagHelp)
    let addr = spec.options.first { $0.names == ["-addr"] }
    #expect(addr?.argument == .required)
    #expect(addr?.description == "listen address (default \":8080\")")
    let version = spec.options.first { $0.names == ["-version"] }
    #expect(version?.argument == nil)
    #expect(version?.description == "print the version and exit")
    // A single space before prose is a description, not an argument.
    let verbose = spec.options.first { $0.names == ["-v"] }
    #expect(verbose?.argument == nil)
    #expect(verbose?.description == "verbose output")
}

@Test func bsdUsageLineYieldsNothing() {
    let spec = HelpParser.parse("usage: ls [-@ABCFGHILOPRSTUWXabcdefghiklmnopqrstuvwxy1%,] [--color=when] [-D format] [file ...]\n")
    #expect(spec.isEmpty)
}

@Test func stripsColorAndOverstrike() {
    let colored = "\u{1B}[1mOptions:\u{1B}[0m\n  \u{1B}[32m-h, --help\u{1B}[0m  Show help\nN\u{8}NAME\n"
    #expect(HelpParser.stripANSI(colored) == "Options:\n  -h, --help  Show help\nNAME\n")
    let spec = HelpParser.parse(colored)
    #expect(spec.options.first?.names == ["-h", "--help"])
}

@Test func exampleColumnIsDroppedFromDescriptions() {
    let bunLike = """
    Commands:
      run       ./my-script.ts       Execute a file with Bun
      test                           Run unit tests with Bun
    """
    let spec = HelpParser.parse(bunLike)
    #expect(spec.subcommands.map(\.description) == ["Execute a file with Bun", "Run unit tests with Bun"])
}

private let groupedHelp = """
Deno: A modern JavaScript and TypeScript runtime

Usage: deno [OPTIONS] [COMMAND]

Commands:
  Execution:
    run          Run a JavaScript or TypeScript program, or a task
                  deno run main.ts  |  deno run --allow-net=google.com main.ts
    serve        Run a server
                  deno serve main.ts

  Dependency management:
    add          Add dependencies
    approve-scripts Approve npm lifecycle scripts

Options:
  -h, --help
          Print help (see a summary with '-h')
  -L, --log-level <log-level>
          Set log level [possible values: trace, debug, info]
"""

@Test func parsesNestedCommandGroupsAndSkipsExamples() {
    let spec = HelpParser.parse(groupedHelp, command: "deno")
    #expect(spec.subcommands.map { $0.names[0] } == ["run", "serve", "add", "approve-scripts"])
    #expect(spec.subcommands[0].description == "Run a JavaScript or TypeScript program, or a task")
    #expect(spec.subcommands[1].description == "Run a server")
    let level = spec.options.first { $0.names.contains("-L") }
    #expect(level?.names == ["-L", "--log-level"])
    #expect(level?.argument == .required)
    #expect(level?.description == "Set log level [possible values: trace, debug, info]")
    // Not a header: has a sentence in it.
    #expect(spec.description == "Deno: A modern JavaScript and TypeScript runtime")
}

private let freeGroupHelp = """
Usage: pnpm [command] [flags]

Manage your dependencies:
      add                  Installs a package and any packages that it depends
                           on. By default, any new package is installed as a
                           prod dependency
   i, install              Install all dependencies for a project
  ln, link                 Connect the local project to another one

Options:
  -r, --recursive          Run the command for each project in the workspace
"""

@Test func parsesFreeFormCommandGroupsWithAliasesFirst() {
    let spec = HelpParser.parse(freeGroupHelp, command: "pnpm")
    #expect(spec.subcommands.map(\.names) == [["add"], ["i", "install"], ["ln", "link"]])
    #expect(spec.subcommands[0].description
        == "Installs a package and any packages that it depends on. By default, any new package is installed as a prod dependency")
    #expect(spec.options.first?.names == ["-r", "--recursive"])
}

// MARK: - Learned specs flow through the engine and parser

private struct FixedEngine: SpecProviding {
    let node: SpecNode
    let name: String
    func spec(for command: String) -> SpecNode? { command == name ? node : nil }
}

@Test func derivedSpecCompletesLikeACorpusSpec() throws {
    let spec = HelpParser.parse(commanderHelp)
    let data = try JSONSerialization.data(withJSONObject: spec.figObject(name: "claude"))
    let engine = SpecEngine()
    let node = try #require(engine.evaluateJSON(String(decoding: data, as: UTF8.self)))
    let parser = CompletionParser(engine: FixedEngine(node: node, name: "claude"))

    let options = parser.complete(buffer: "claude --a", cursor: 10)
    #expect(options.suggestions.map(\.display) == ["--add-dir", "--allowed-tools", "--autocompact"])
    #expect(options.suggestions[1].aliases == ["--allowedTools"])
    #expect(options.unexploredPath == nil)

    // "--add-dir" takes a value: the next word is its argument, not a subcommand.
    let afterValue = parser.complete(buffer: "claude --add-dir x ", cursor: 19)
    #expect(afterValue.suggestions.map(\.display).contains("mcp"))

    let sub = parser.complete(buffer: "claude mc", cursor: 9)
    #expect(sub.suggestions.map(\.display) == ["mcp"])
    #expect(sub.suggestions[0].detail == "Configure and manage MCP servers")

    // Reaching a learned subcommand asks for its exploration.
    let inside = parser.complete(buffer: "claude mcp ", cursor: 11)
    #expect(inside.suggestions.isEmpty)
    #expect(inside.unexploredPath == ["claude", "mcp"])
}

@Test func unknownCommandIsReportedForLearning() {
    let engine = SpecEngine()
    let parser = CompletionParser(engine: engine)
    #expect(parser.complete(buffer: "frobnicate --v", cursor: 14).unknownCommand == "frobnicate")
    #expect(parser.complete(buffer: "sudo ./frob --v", cursor: 15).unknownCommand == "./frob")
    #expect(parser.complete(buffer: "frobnicate", cursor: 10).unknownCommand == nil)  // no space yet
}

// MARK: - The gate

@Test func shebangClassification() {
    #expect(DerivedSpecStore.classifyShebang("#!/usr/bin/env node") == .runnable)
    #expect(DerivedSpecStore.classifyShebang("#!/usr/bin/env -S python3 -u") == .runnable)
    #expect(DerivedSpecStore.classifyShebang("#!/opt/homebrew/bin/python3.12") == .runnable)
    #expect(DerivedSpecStore.classifyShebang("#!/bin/bash") == .unsafe("shell script"))
    #expect(DerivedSpecStore.classifyShebang("#!/usr/bin/env zsh") == .unsafe("shell script"))
    #expect(DerivedSpecStore.classifyShebang("#!/bin/sh -e") == .unsafe("shell script"))
}

@Test func bareNamesOnly() {
    #expect(DerivedSpecStore.isBareName("claude"))
    #expect(DerivedSpecStore.isBareName("python3.12"))
    #expect(!DerivedSpecStore.isBareName("./deploy"))
    #expect(!DerivedSpecStore.isBareName("/usr/bin/env"))
    #expect(!DerivedSpecStore.isBareName("-v"))
    #expect(!DerivedSpecStore.isBareName(""))
}

@Test func systemBinariesAreMachO() {
    #expect(DerivedSpecStore.classify(URL(fileURLWithPath: "/bin/ls")) == .runnable)
    #expect(DerivedSpecStore.resolve("ls", searchPath: "/nonexistent:/bin")?.path == "/bin/ls")
    #expect(DerivedSpecStore.resolve("ls", searchPath: "/nonexistent") == nil)
}
