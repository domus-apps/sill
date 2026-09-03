import Foundation

/* Specs Sill teaches itself. For a command the corpus doesn't know, run it
   once with `--help`, read the options and subcommands out of the answer
   (HelpParser), and keep the result as a Fig-shaped JSON file under
   Application Support — nothing leaves this Mac. Subcommands are explored
   the same way, one level at a time, the first time the user reaches them.
   The engine reads these files exactly like corpus specs.

   Running an unknown program is the one risky step, so the gate is strict:
   a bare command name (no path), resolved through the session's own PATH
   to a real Mach-O executable or an interpreter script whose interpreter
   is not a shell — a hand-written shell script may ignore its arguments and
   simply do its thing. Anything else is skipped, and remembered as skipped
   until the file changes. */
final class DerivedSpecStore {
    /// Posted on the main queue after a file changed; userInfo["command"]
    /// names the root command, or is absent when everything was forgotten.
    static let updated = Notification.Name("Sill.DerivedSpecUpdated")

    static var directory: URL { SpecStore.supportDirectory.appendingPathComponent("derived") }
    /// `cmd sub sub` is as deep as exploration goes (root included).
    static let maxDepth = 3
    static let timeout: TimeInterval = 2.5

    private let queue = DispatchQueue(label: "sill.derive", qos: .utility)
    /// Keys (command, or "command sub …") being probed right now.
    private var inFlight: Set<String> = []
    /// Keys already dealt with since launch: fresh on disk, unresolvable,
    /// or unsafe — no need to stat the world again on every keystroke.
    private var settled: Set<String> = []
    /// Commands known to have no usable file (absent or failed), so a
    /// keystroke doesn't re-read the disk.
    private var missing: Set<String> = []

    init() {}

    // MARK: - Reading

    /// The Fig-shaped JSON for a learned command, or nil.
    func specJSON(for command: String) -> String? {
        guard !missing.contains(command) else { return nil }
        guard let data = try? Data(contentsOf: Self.fileURL(command)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !Self.isFailed(object)
        else {
            missing.insert(command)
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Commands with a usable learned spec.
    var learnedCommands: [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: Self.directory.path)
        else { return [] }
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            let command = String(name.dropLast(5))
            guard let object = Self.loadObject(command), !Self.isFailed(object) else { return nil }
            return command
        }.sorted()
    }

    func forgetAll() {
        try? FileManager.default.removeItem(at: Self.directory)
        settled.removeAll()
        missing.removeAll()
        NotificationCenter.default.post(name: Self.updated, object: self)
    }

    // MARK: - Learning

    /// Learns `command` from `--help` if it isn't known yet (or its
    /// executable changed since). Returns immediately; the result arrives
    /// as an `updated` notification. Main thread.
    func ensure(command: String, searchPath: String) {
        guard Self.isBareName(command), !inFlight.contains(command),
              !settled.contains(command)
        else { return }
        settled.insert(command)
        guard let executable = Self.resolve(command, searchPath: searchPath) else { return }
        let stamp = Self.stamp(of: executable)
        if let existing = Self.loadObject(command), Self.sameStamp(Self.stamp(in: existing), stamp) {
            return  // fresh — learned or deliberately skipped
        }
        inFlight.insert(command)
        queue.async { [weak self] in
            _ = Self.learn(command: command, executable: executable, stamp: stamp,
                           searchPath: searchPath)
            DispatchQueue.main.async {
                self?.finished(key: command, command: command)
            }
        }
    }

    /// Learns the options of a subcommand the user has reached
    /// (`path` = root name, then subcommand names). Main thread.
    func explore(path: [String], searchPath: String) {
        guard path.count >= 2, path.count <= Self.maxDepth, let command = path.first,
              Self.isBareName(command)
        else { return }
        let key = path.joined(separator: " ")
        guard !inFlight.contains(key), !settled.contains(key) else { return }
        settled.insert(key)
        guard let root = Self.loadObject(command), !Self.isFailed(root),
              let node = Self.node(at: path.dropFirst(), in: root),
              node["_sillUnexplored"] as? Bool == true,
              let executable = Self.resolve(command, searchPath: searchPath),
              case .runnable = Self.classify(executable)
        else { return }
        inFlight.insert(key)
        queue.async { [weak self] in
            _ = Self.exploreNow(path: path, executable: executable, searchPath: searchPath)
            DispatchQueue.main.async {
                self?.finished(key: key, command: command)
            }
        }
    }

    private func finished(key: String, command: String) {
        inFlight.remove(key)
        missing.remove(command)
        NotificationCenter.default.post(name: Self.updated, object: self,
                                        userInfo: ["command": command])
    }

    /// Synchronous variant for the `--derive` CLI harness and tests: learns
    /// (or refuses) right now and says what happened.
    static func learnNow(command: String, searchPath: String) -> String {
        guard isBareName(command) else { return "\(command): not a bare command name" }
        guard let executable = resolve(command, searchPath: searchPath) else {
            return "\(command): not found in PATH (builtin, alias or function?)"
        }
        return learn(command: command, executable: executable, stamp: stamp(of: executable),
                     searchPath: searchPath)
    }

    private static func learn(command: String, executable: URL, stamp: [String: Any],
                              searchPath: String) -> String {
        if case .unsafe(let reason) = classify(executable) {
            write(failure(command: command, stamp: stamp, reason: reason), for: command)
            return "\(command): skipped — \(reason) (\(executable.path))"
        }
        guard let output = runHelp(executable, arguments: ["--help"], searchPath: searchPath) else {
            write(failure(command: command, stamp: stamp, reason: "no output from --help"),
                  for: command)
            return "\(command): --help produced nothing"
        }
        let spec = HelpParser.parse(output, command: command)
        guard !spec.isEmpty else {
            write(failure(command: command, stamp: stamp, reason: "help text not recognized"),
                  for: command)
            return "\(command): couldn't read options or commands out of --help"
        }
        var object = spec.figObject(name: command)
        object["_sill"] = stamp
        write(object, for: command)
        return "\(command): learned \(spec.options.count) options, \(spec.subcommands.count) subcommands"
    }

    private static func exploreNow(path: [String], executable: URL, searchPath: String) -> String {
        let key = path.joined(separator: " ")
        let output = runHelp(executable, arguments: Array(path.dropFirst()) + ["--help"],
                             searchPath: searchPath)
        let spec = output.map { HelpParser.parse($0, command: path[0]) }
        // Re-read: another exploration may have written since.
        guard let root = loadObject(path[0]) else { return "\(key): root spec vanished" }
        let updated = updating(root, path: path.dropFirst()) { node in
            var node = node
            node.removeValue(forKey: "_sillUnexplored")
            if let spec, !spec.isEmpty {
                let learned = spec.figObject(name: path.last ?? "")
                if let options = learned["options"] { node["options"] = options }
                if let subcommands = learned["subcommands"], path.count < maxDepth {
                    node["subcommands"] = subcommands
                }
            }
            return node
        }
        write(updated, for: path[0])
        if let spec, !spec.isEmpty {
            return "\(key): learned \(spec.options.count) options, \(spec.subcommands.count) subcommands"
        }
        return "\(key): nothing recognizable in --help"
    }

    // MARK: - The gate

    static func isBareName(_ command: String) -> Bool {
        !command.isEmpty && command.count <= 64 && !command.hasPrefix("-")
            && command.allSatisfy { $0.isLetter || $0.isNumber || "._+-".contains($0) }
    }

    /// The first executable regular file named `command` along `searchPath`.
    static func resolve(_ command: String, searchPath: String) -> URL? {
        let fm = FileManager.default
        for directory in searchPath.split(separator: ":") where !directory.isEmpty {
            let path = String(directory) + "/" + command
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  fm.isExecutableFile(atPath: path)
            else { continue }
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    enum Safety: Equatable {
        case runnable
        case unsafe(String)
    }

    private static let shells: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh", "nu", "elvish", "xonsh",
    ]

    /// Mach-O binaries and non-shell interpreter scripts may be asked for
    /// help; shell scripts and anything unrecognized may not.
    static func classify(_ executable: URL) -> Safety {
        guard let handle = try? FileHandle(forReadingFrom: executable),
              let head = try? handle.read(upToCount: 512), head.count >= 4
        else { return .unsafe("unreadable") }
        try? handle.close()
        let magic = [UInt8](head.prefix(4))
        let machO: Set<[UInt8]> = [
            [0xFE, 0xED, 0xFA, 0xCE], [0xFE, 0xED, 0xFA, 0xCF],
            [0xCE, 0xFA, 0xED, 0xFE], [0xCF, 0xFA, 0xED, 0xFE],
            [0xCA, 0xFE, 0xBA, 0xBE], [0xBE, 0xBA, 0xFE, 0xCA],
        ]
        if machO.contains(magic) { return .runnable }
        guard magic[0] == 0x23, magic[1] == 0x21 else { return .unsafe("not a program") }
        let firstLine = String(decoding: head, as: UTF8.self)
            .split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return classifyShebang(firstLine)
    }

    static func classifyShebang(_ line: String) -> Safety {
        var words = line.dropFirst(2).split(separator: " ").map(String.init)
        guard let first = words.first else { return .unsafe("empty interpreter") }
        var interpreter = (first as NSString).lastPathComponent
        if interpreter == "env" {
            words.removeFirst()
            // `env -S`, `env -i`: skip flags to the program name.
            words.removeAll { $0.hasPrefix("-") }
            guard let program = words.first else { return .unsafe("empty interpreter") }
            interpreter = (program as NSString).lastPathComponent
        }
        if shells.contains(interpreter) { return .unsafe("shell script") }
        return .runnable
    }

    // MARK: - Running

    /// `executable arguments…` with a quiet environment: no pager, no color,
    /// no terminal, no stdin, in a scratch directory, killed after a few
    /// seconds. stdout and stderr both count — plenty of tools print help
    /// to stderr.
    static func runHelp(_ executable: URL, arguments: [String], searchPath: String) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        environment["CLICOLOR"] = "0"
        environment["FORCE_COLOR"] = "0"
        environment["PAGER"] = "cat"
        environment["MANPAGER"] = "cat"
        environment["GIT_PAGER"] = "cat"
        environment["COLUMNS"] = "120"
        environment["LINES"] = "50"
        process.environment = environment
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("sill-help", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        process.currentDirectoryURL = scratch
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.qualityOfService = .utility
        do { try process.run() } catch { return nil }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let collected = OutputBox()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                if collected.append(chunk) > 512 << 10 {
                    process.terminate()
                    break
                }
            }
            drained.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 0.5)
            }
        }
        // The write end closes with the process — unless a grandchild holds
        // it, hence the bounded wait.
        _ = drained.wait(timeout: .now() + 0.5)
        let text = String(decoding: collected.data, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    private final class OutputBox: @unchecked Sendable {
        private var storage = Data()
        private let lock = NSLock()
        var data: Data { lock.withLock { storage } }
        func append(_ chunk: Data) -> Int {
            lock.withLock {
                storage.append(chunk)
                return storage.count
            }
        }
    }

    // MARK: - Files

    static func fileURL(_ command: String) -> URL {
        directory.appendingPathComponent(command + ".json")
    }

    static func loadObject(_ command: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: fileURL(command)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func write(_ object: [String: Any], for command: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: object,
                                                  options: [.sortedKeys, .prettyPrinted])
            try data.write(to: fileURL(command), options: .atomic)
        } catch {
            NSLog("Sill: couldn't save the learned spec for %@: %@", command,
                  error.localizedDescription)
        }
    }

    static func isFailed(_ object: [String: Any]) -> Bool {
        (object["_sill"] as? [String: Any])?["failed"] as? Bool == true
    }

    /// Identity of the executable a file was learned from: path, mtime,
    /// size. A changed binary is learned again.
    static func stamp(of executable: URL) -> [String: Any] {
        let resolved = executable.resolvingSymlinksInPath()
        let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path)
        let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        return ["path": resolved.path, "mtime": mtime.rounded(), "size": size,
                "generatedAt": Date().timeIntervalSince1970.rounded()]
    }

    private static func stamp(in object: [String: Any]) -> [String: Any]? {
        guard let meta = object["_sill"] as? [String: Any] else { return nil }
        return ["path": meta["path"] as Any, "mtime": meta["mtime"] as Any, "size": meta["size"] as Any]
    }

    /// Loose equality for the three identity fields.
    private static func sameStamp(_ lhs: [String: Any]?, _ rhs: [String: Any]) -> Bool {
        guard let lhs else { return false }
        return lhs["path"] as? String == rhs["path"] as? String
            && lhs["mtime"] as? Double == rhs["mtime"] as? Double
            && lhs["size"] as? Int == rhs["size"] as? Int
    }

    private static func failure(command: String, stamp: [String: Any],
                                reason: String) -> [String: Any] {
        var meta = stamp
        meta["failed"] = true
        meta["reason"] = reason
        return ["name": command, "_sill": meta]
    }

    /// The subcommand object reached by following `path` names.
    static func node(at path: ArraySlice<String>, in object: [String: Any]) -> [String: Any]? {
        guard let name = path.first else { return object }
        guard let subcommands = object["subcommands"] as? [[String: Any]],
              let child = subcommands.first(where: { names(of: $0).contains(name) })
        else { return nil }
        return node(at: path.dropFirst(), in: child)
    }

    private static func updating(_ object: [String: Any], path: ArraySlice<String>,
                                 transform: ([String: Any]) -> [String: Any]) -> [String: Any] {
        guard let name = path.first else { return transform(object) }
        var object = object
        guard var subcommands = object["subcommands"] as? [[String: Any]],
              let index = subcommands.firstIndex(where: { names(of: $0).contains(name) })
        else { return object }
        subcommands[index] = updating(subcommands[index], path: path.dropFirst(),
                                      transform: transform)
        object["subcommands"] = subcommands
        return object
    }

    private static func names(of node: [String: Any]) -> [String] {
        if let name = node["name"] as? String { return [name] }
        return node["name"] as? [String] ?? []
    }
}
