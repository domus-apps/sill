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
   signal that a command is worth a row.

   Homebrew gives a second signal: what the user asked it to install. The
   commands in its bin that come from a formula installed by name, or from a
   cask, are offered too, described by the package's own `desc` — `mo` from
   mole has no definition anywhere, but it was installed to be typed. What a
   formula pulled in as a dependency (gettext's msgfmt and friends) stays
   out, like /usr/bin does. */
final class CommandCatalog: CommandCatalogProviding {
    private let specDirectories: [URL]
    private let derived: DerivedSpecStore?

    /// name → description for every spec file, from the bundle's index.
    private var specs: [String: String]?
    /// What was found along each distinct PATH string, and the folders'
    /// modification times then — an install or uninstall shows up as a
    /// changed folder, and only then is the PATH walked again.
    private var scans: [String: (scan: PathScan, stamps: [timespec?])] = [:]

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
        let path = scanned(searchPath)
        let lower = prefix.lowercased()
        var result: [(name: String, description: String)] = known.compactMap { name, description in
            guard name.lowercased().hasPrefix(lower),
                  path.names.contains(name) || Self.builtins.contains(name)
            else { return nil }
            return (name, description.isEmpty ? path.installed[name] ?? "" : description)
        }
        for (name, description) in path.installed
        where known[name] == nil && name.lowercased().hasPrefix(lower) {
            result.append((name, description))
        }
        return result
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

    /// What one walk along PATH found.
    struct PathScan {
        /// Every executable, by name; the first on PATH wins a name.
        var names: Set<String> = []
        /// Executables in a Homebrew bin that the user installed on purpose,
        /// with the package's description ("" when it has none).
        var installed: [String: String] = [:]
    }

    private func scanned(_ searchPath: String) -> PathScan {
        let stamps = Self.directories(searchPath).map(Self.modificationTime)
        if let cached = scans[searchPath], cached.stamps.elementsEqual(stamps, by: Self.same) {
            return cached.scan
        }
        let found = Self.scan(searchPath)
        scans[searchPath] = (found, stamps)
        return found
    }

    /// Every executable regular file along PATH, by name. A few thousand
    /// stats, again only when a folder on PATH changes.
    static func scan(_ searchPath: String) -> PathScan {
        let fm = FileManager.default
        var result = PathScan()
        var packages = Homebrew.Packages()
        for directory in directories(searchPath) {
            guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { continue }
            let prefix = Homebrew.prefix(ofBin: directory)
            for entry in entries where !result.names.contains(entry) {
                var isDirectory: ObjCBool = false
                let path = directory + "/" + entry
                guard fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                      fm.isExecutableFile(atPath: path)
                else { continue }
                result.names.insert(entry)
                if let prefix, let description = packages.description(of: path, prefix: prefix) {
                    result.installed[entry] = description
                }
            }
        }
        return result
    }

    private static func directories(_ searchPath: String) -> [String] {
        searchPath.split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    private static func modificationTime(_ path: String) -> timespec? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return info.st_mtimespec
    }

    private static func same(_ a: timespec?, _ b: timespec?) -> Bool {
        a?.tv_sec == b?.tv_sec && a?.tv_nsec == b?.tv_nsec
    }
}

/* Reading Homebrew's own records, never running brew (a second or more per
   call). A formula's keg keeps INSTALL_RECEIPT.json, whose
   `installed_on_request` tells a formula the user named apart from one that
   came along as a dependency, and a copy of the formula under .brew/, whose
   `desc "…"` line is the description `brew info` prints. A cask keeps its
   installed caskfile under .metadata/<version>/<timestamp>/Casks/, as JSON
   or Ruby. */
enum Homebrew {
    /// The Homebrew prefix `directory` is the bin (or sbin) of, when it is
    /// one: a folder whose parent has a Cellar or a Caskroom.
    static func prefix(ofBin directory: String) -> String? {
        let url = URL(fileURLWithPath: directory).standardizedFileURL
        guard ["bin", "sbin"].contains(url.lastPathComponent) else { return nil }
        let prefix = url.deletingLastPathComponent().path
        let fm = FileManager.default
        guard fm.fileExists(atPath: prefix + "/Cellar") || fm.fileExists(atPath: prefix + "/Caskroom")
        else { return nil }
        return prefix
    }

    /// Packages read during one walk along PATH, so a formula with twenty
    /// commands is read once.
    struct Packages {
        private var formulae: [String: String?] = [:]
        private var casks: [String: String] = [:]

        /// The description to show for the command at `path` in `prefix`'s
        /// bin, or nil when it belongs to a dependency. A command that isn't
        /// a formula's or a cask's (linked or put there by hand) is the
        /// user's doing too and is offered undescribed.
        mutating func description(of path: String, prefix: String) -> String? {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if let keg = Self.package(in: prefix + "/Cellar/", of: resolved, depth: 2) {
                if let known = formulae[keg] { return known }
                let read = Self.formula(at: keg)
                formulae[keg] = read
                return read
            }
            if let root = Self.package(in: prefix + "/Caskroom/", of: resolved, depth: 1) {
                if let known = casks[root] { return known }
                let read = Self.cask(at: root)
                casks[root] = read
                return read
            }
            return ""
        }

        /// `<root><name>` (depth 1) or `<root><name>/<version>` (depth 2)
        /// when `path` lies inside it.
        private static func package(in root: String, of path: String, depth: Int) -> String? {
            guard path.hasPrefix(root) else { return nil }
            let components = path.dropFirst(root.count).split(separator: "/", maxSplits: depth)
            guard components.count > depth else { return nil }
            return root + components.prefix(depth).joined(separator: "/")
        }

        /// A keg's description, or nil when it was installed as a dependency.
        private static func formula(at keg: String) -> String? {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: keg + "/INSTALL_RECEIPT.json")),
               let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               receipt["installed_on_request"] as? Bool == false {
                return nil
            }
            let name = (keg as NSString).deletingLastPathComponent.split(separator: "/").last.map(String.init) ?? ""
            let source = try? String(contentsOfFile: keg + "/.brew/\(name).rb", encoding: .utf8)
            return source.flatMap(desc(inRuby:)) ?? ""
        }

        private static func cask(at root: String) -> String {
            let token = (root as NSString).lastPathComponent
            let fm = FileManager.default
            let metadata = root + "/.metadata"
            // The newest install: the highest timestamp under any version.
            let installs = ((try? fm.contentsOfDirectory(atPath: metadata)) ?? []).flatMap { version in
                ((try? fm.contentsOfDirectory(atPath: metadata + "/" + version)) ?? [])
                    .map { (stamp: $0, path: metadata + "/" + version + "/" + $0) }
            }
            guard let newest = installs.max(by: { $0.stamp < $1.stamp }) else { return "" }
            let casks = newest.path + "/Casks/" + token
            if let data = try? Data(contentsOf: URL(fileURLWithPath: casks + ".json")),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object["desc"] as? String ?? ""
            }
            let source = try? String(contentsOfFile: casks + ".rb", encoding: .utf8)
            return source.flatMap(desc(inRuby:)) ?? ""
        }
    }

    /// The `desc "…"` line of a formula or cask written in Ruby.
    static func desc(inRuby source: String) -> String? {
        guard let match = source.firstMatch(of: #/(?m)^\s*desc\s+"((?:[^"\\]|\\.)*)"/#) else { return nil }
        return String(match.1).replacingOccurrences(of: "\\\"", with: "\"")
    }
}
