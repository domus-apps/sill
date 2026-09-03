import Foundation

/// Where first-word suggestions come from.
protocol CommandCatalogProviding {
    /// Commands the user could run whose name starts with `prefix`, with a
    /// one-line description when one is known.
    func commands(matching prefix: String, searchPath: String) -> [(name: String, description: String)]
}

/* The commands worth offering when the first word is being typed: those
   Sill has a definition for — the corpus (with the descriptions the bundle's
   index carries), overrides, and commands learned from --help — narrowed to
   what is actually runnable here: an executable on the session's PATH, or a
   shell builtin that has a definition (cd, export…). Listing every binary in
   /usr/bin would drown the list in things nobody types; a definition is the
   signal that a command is worth a row. */
final class CommandCatalog: CommandCatalogProviding {
    private let specDirectories: [URL]
    private let derived: DerivedSpecStore?

    /// name → description for every spec file, from the bundle's index.
    private var specs: [String: String]?
    /// Executable names found along each distinct PATH string.
    private var executables: [String: Set<String>] = [:]

    /// Builtins that have specs in the corpus — not on any PATH, but typed
    /// as often as anything that is.
    static let builtins: Set<String> = [
        "cd", "export", "source", "alias", "unalias", "unset", "set", "exec", "eval",
        "type", "pushd", "popd", "jobs", "fg", "bg", "history", "exit", "echo", "printf",
        "read", "kill", "wait", "time", "command", "builtin", "hash", "ulimit", "umask",
    ]

    init(specDirectories: [URL], derived: DerivedSpecStore?) {
        self.specDirectories = specDirectories
        self.derived = derived
        for name in [SpecStore.updated, DerivedSpecStore.updated] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                self?.specs = nil
            }
        }
    }

    func commands(matching prefix: String, searchPath: String) -> [(name: String, description: String)] {
        guard !prefix.isEmpty else { return [] }
        let known = knownSpecs()
        let runnable = executables(along: searchPath)
        let lower = prefix.lowercased()
        return known.compactMap { name, description in
            guard name.lowercased().hasPrefix(lower),
                  runnable.contains(name) || Self.builtins.contains(name)
            else { return nil }
            return (name, description)
        }
    }

    // MARK: - Definitions

    private func knownSpecs() -> [String: String] {
        if let specs { return specs }
        var result: [String: String] = [:]
        // Later directories are lower priority: the first index wins a name.
        for directory in specDirectories.reversed() {
            for (name, description) in Self.readIndex(in: directory) {
                result[name] = description
            }
        }
        for name in derived?.learnedCommands ?? [] {
            let object = DerivedSpecStore.loadObject(name)
            result[name] = object?["description"] as? String ?? result[name] ?? ""
        }
        specs = result
        return result
    }

    /// The bundle's index.json: `files` names every spec, `descriptions`
    /// (bundles built since 1.1) maps names to their one-liners. Nested
    /// loadSpec files ("aws/s3") are not commands and are skipped.
    static func readIndex(in directory: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = object["files"] as? [String]
        else { return [:] }
        let descriptions = object["descriptions"] as? [String: String] ?? [:]
        var result: [String: String] = [:]
        for file in files where file.hasSuffix(".js") && !file.contains("/") {
            let name = String(file.dropLast(3))
            result[name] = descriptions[name] ?? ""
        }
        return result
    }

    // MARK: - PATH

    private func executables(along searchPath: String) -> Set<String> {
        if let cached = executables[searchPath] { return cached }
        let found = Self.scan(searchPath)
        executables[searchPath] = found
        return found
    }

    /// Every executable regular file along PATH, by name. A few thousand
    /// stats, once per distinct PATH.
    static func scan(_ searchPath: String) -> Set<String> {
        let fm = FileManager.default
        var names: Set<String> = []
        for directory in searchPath.split(separator: ":").map(String.init) where !directory.isEmpty {
            guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where !names.contains(entry) {
                var isDirectory: ObjCBool = false
                let path = directory + "/" + entry
                if fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                   fm.isExecutableFile(atPath: path) {
                    names.insert(entry)
                }
            }
        }
        return names
    }
}
