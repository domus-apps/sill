import Foundation

/// Main-thread cache, with config reads on a worker queue. Git resolves global,
/// local, worktree, and conditional includes itself; alias bodies are never run.
final class GitAliasStore {
    struct Context: Hashable {
        var cwd: String
        var options: [String] = []

        init?(cwd: String, tokens: [Token]) {
            guard !cwd.isEmpty, let subcommand = AliasExpansion.gitSubcommand(in: tokens) else { return nil }
            self.cwd = cwd
            let configOptions: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace"]
            var index = 1
            while index < subcommand {
                let word = tokens[index].text
                if configOptions.contains(word), index + 1 < subcommand {
                    options += [word, tokens[index + 1].text]
                    index += 2
                    continue
                }
                if word == "--bare" || word.hasPrefix("-C") || word.hasPrefix("-c")
                    || configOptions.contains(where: { word.hasPrefix($0 + "=") }) {
                    options.append(word)
                }
                index += 1
            }
        }
    }

    private struct Entry {
        var aliases: [String: String]
        var date: Date
    }
    private var cache: [Context: Entry] = [:]
    private var pending: [Context: [() -> Void]] = [:]
    private let queue = DispatchQueue(label: "sill.git-aliases", qos: .userInitiated)

    func aliases(in context: Context, updated: @escaping () -> Void) -> [String: String] {
        let cached = cache[context]
        if let cached, Date().timeIntervalSince(cached.date) < 2 { return cached.aliases }
        if pending[context] != nil {
            pending[context]?.append(updated)
            return cached?.aliases ?? [:]
        }
        pending[context] = [updated]
        queue.async { [weak self] in
            let aliases = Self.read(context)
            DispatchQueue.main.async {
                guard let self else { return }
                let previous = self.cache[context]?.aliases
                // Bound memory when moving through many repositories.
                if self.cache.count >= 64, let oldest = self.cache.min(by: { $0.value.date < $1.value.date })?.key {
                    self.cache.removeValue(forKey: oldest)
                }
                self.cache[context] = Entry(aliases: aliases, date: Date())
                let callbacks = self.pending.removeValue(forKey: context) ?? []
                if previous != aliases { callbacks.forEach { $0() } }
            }
        }
        return cached?.aliases ?? [:]
    }

    /// `--null --get-regexp` emits name + newline + value + NUL. Splitting
    /// only the first newline preserves multiline shell aliases. Last wins.
    static func decode(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        for record in String(decoding: data, as: UTF8.self).split(separator: "\0") {
            guard let newline = record.firstIndex(of: "\n") else { continue }
            let key = record[..<newline]
            guard key.hasPrefix("alias."), key.count > 6 else { continue }
            result[String(key.dropFirst(6))] = String(record[record.index(after: newline)...])
        }
        return result
    }

    static func read(_ context: Context, environment: [String: String]? = nil) -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = context.options + ["config", "--null", "--includes", "--get-regexp", "^alias\\."]
        process.currentDirectoryURL = URL(fileURLWithPath: context.cwd)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return [:] }

        let output = Output()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                if !output.append(chunk) { process.terminate(); break }
            }
            drained.signal()
        }
        if exited.wait(timeout: .now() + 2) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 0.2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 0.2)
            }
            return [:]
        }
        guard drained.wait(timeout: .now() + 0.2) == .success,
              process.terminationStatus == 0, let data = output.data else { return [:] }
        return decode(data)
    }

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        private var exceededLimit = false
        var data: Data? { lock.withLock { exceededLimit ? nil : storage } }
        func append(_ data: Data) -> Bool {
            lock.withLock {
                guard storage.count + data.count <= 1 << 20 else {
                    exceededLimit = true
                    return false
                }
                storage.append(data)
                return true
            }
        }
    }
}
