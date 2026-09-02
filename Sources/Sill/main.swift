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
    let engine = SpecEngine(specDirectories: directories)
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
