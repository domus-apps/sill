import AppKit

/* Headless one-shot mode for development and scripted verification:
   `Sill --complete "git ch"` parses the buffer against the spec corpus
   (SILL_SPEC_DIR or the installed bundle) and prints the suggestions. */
if let index = CommandLine.arguments.firstIndex(of: "--complete"),
   CommandLine.arguments.count > index + 1 {
    let buffer = CommandLine.arguments[index + 1]
    var directories: [URL] = []
    if let dir = ProcessInfo.processInfo.environment["SILL_SPEC_DIR"] {
        directories.append(URL(fileURLWithPath: dir))
    }
    let engine = SpecEngine(specDirectories: directories, derived: DerivedSpecStore())
    let result = CompletionParser(engine: engine)
        .complete(buffer: buffer, cursor: buffer.count)
    for s in result.suggestions {
        print("\(s.display)\t\(s.kind)\t\(s.detail.prefix(72))")
    }
    if let pending = result.pendingArg {
        print("(pending arg \"\(pending.node.primaryName)\": templates=\(pending.node.templates), generators=\(pending.node.generators.count))")
        let cwd = FileManager.default.currentDirectoryPath
        for s in TemplateResolver.suggestions(
            templates: pending.node.templates, partial: pending.partial, cwd: cwd) {
            print("\(s.display)\t\(s.kind)\ttemplate")
        }
        if !pending.node.generators.isEmpty {
            // GeneratorRunner delivers on the main queue — pump the run loop.
            var finished = false
            let runner = GeneratorRunner()  // kept alive until delivery
            runner.run(arg: pending.node, tokens: result.commandTokens,
                                  partial: pending.partial, cwd: cwd, sid: "cli") { generated in
                for s in generated.prefix(12) {
                    print("\(s.display)\t\(s.kind)\tgenerator\t\(s.detail.prefix(40))")
                }
                finished = true
            }
            let deadline = Date().addingTimeInterval(5)
            withExtendedLifetime(runner) {
                while !finished, Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
            }
        }
    }
    if let unknown = result.unknownCommand {
        print("(no spec for \"\(unknown)\" — try --derive \(unknown))")
    }
    if let path = result.unexploredPath {
        print("(learned subcommand not explored yet: \(path.joined(separator: " ")))")
    }
    exit(0)
}

/* `Sill --derive <command>` learns a command from its --help right now,
   using this process's PATH, and says what it found — the file then serves
   `--complete` like any corpus spec. */
if let index = CommandLine.arguments.firstIndex(of: "--derive"),
   CommandLine.arguments.count > index + 1 {
    let command = CommandLine.arguments[index + 1]
    let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    print(DerivedSpecStore.learnNow(command: command, searchPath: searchPath))
    if let object = DerivedSpecStore.loadObject(command),
       let data = try? JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
    }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--probe-text"),
   CommandLine.arguments.count > index + 1 {
    AXProbe.probeText(bundleID: CommandLine.arguments[index + 1])
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--probe-focus"),
   CommandLine.arguments.count > index + 1 {
    AXProbe.run(bundleID: CommandLine.arguments[index + 1])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
/* Menu bar only — no Dock icon. The bundled build also sets LSUIElement,
   but this makes plain `swift run` behave the same way. */
app.setActivationPolicy(.accessory)
app.run()
