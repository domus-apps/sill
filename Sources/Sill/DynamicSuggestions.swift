import Foundation
import JavaScriptCore

/* Dynamic completion sources: fig's `template` (resolved natively) and
   `generators` (a shell script plus an optional JS postProcess). */

enum TemplateResolver {
    /// "filepaths" / "folders" templates, listed natively from the session's
    /// working directory. The partial token may carry a directory prefix
    /// ("src/co") — listing happens in that subdirectory and insertions
    /// replace the whole token. Pre-filtered and pre-scored (path components
    /// don't survive the parser's plain prefix ranking).
    static func suggestions(templates: [String], partial: Token, cwd: String) -> [Suggestion] {
        let foldersOnly = templates.contains("folders") && !templates.contains("filepaths")
        guard templates.contains("filepaths") || templates.contains("folders") else { return [] }

        let text = partial.text
        let slash = text.lastIndex(of: "/")
        let directoryPrefix = slash.map { String(text[...$0]) } ?? ""   // kept in insertions
        let componentPrefix = slash.map { String(text[text.index(after: $0)...]) } ?? text

        var base = directoryPrefix
        if base.hasPrefix("~") {
            base = NSString(string: base).expandingTildeInPath
        }
        let directory = base.hasPrefix("/") ? base : cwd + "/" + base

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: componentPrefix.hasPrefix(".") ? [] : [.skipsHiddenFiles])
        else { return [] }

        return entries.compactMap { url -> Suggestion? in
            let name = url.lastPathComponent
            guard componentPrefix.isEmpty
                || name.lowercased().hasPrefix(componentPrefix.lowercased())
            else { return nil }
            let isDirectory =
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if foldersOnly && !isDirectory { return nil }
            let escaped = shellEscaped(directoryPrefix + name)
            return Suggestion(
                display: name + (isDirectory ? "/" : ""),
                insertText: escaped + (isDirectory ? "/" : " "),
                deleteCount: partial.typedLength,
                detail: "",
                kind: isDirectory ? .folder : .file,
                score: 2)
        }
        .sorted { ($0.kind == .folder ? 0 : 1, $0.display) < ($1.kind == .folder ? 0 : 1, $1.display) }
    }

    static func shellEscaped(_ value: String) -> String {
        var out = ""
        for ch in value {
            if " \t\"'\\$`!*?[](){}<>;&|~#".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}

/* Runs fig generators: `script` in the session's cwd through zsh, then the
   spec's `postProcess`/`splitOn` to turn stdout into suggestions. Results
   are cached briefly per (session, script, cwd) so retyping doesn't fork a
   process per keystroke. */
final class GeneratorRunner {
    private struct CacheKey: Hashable {
        let sid: String
        let script: String
        let cwd: String
    }

    private var cache: [CacheKey: (at: Date, suggestions: [Suggestion])] = [:]
    private let ttl: TimeInterval = 5
    private let queue = DispatchQueue(label: "sill.generators", qos: .userInitiated)

    /// Runs every generator of `arg` and delivers merged suggestions on the
    /// main queue. `generation` lets the caller drop stale replies.
    func run(arg: SpecNode, tokens: [String], partial: Token, cwd: String, sid: String,
             completion: @escaping ([Suggestion]) -> Void) {
        var results: [Suggestion] = []
        let group = DispatchGroup()
        for generator in arg.generators {
            if let custom = generator.objectForKeyedSubscript("custom"), isFunction(custom) {
                group.enter()
                runCustom(generator: generator, custom: custom, tokens: tokens, partial: partial,
                          cwd: cwd, sid: sid) { suggestions in
                    results += suggestions
                    group.leave()
                }
                continue
            }
            guard let script = scriptString(of: generator, tokens: tokens) else { continue }
            let key = CacheKey(sid: sid, script: script, cwd: cwd)
            if let cached = cache[key], Date().timeIntervalSince(cached.at) < ttl {
                results += Self.matching(retargeted(cached.suggestions, partial: partial),
                                         query: partial.text)
                continue
            }
            group.enter()
            queue.async { [weak self] in
                let output = Self.runShell(script, cwd: cwd)
                DispatchQueue.main.async {
                    defer { group.leave() }
                    guard let self, let output else { return }
                    let suggestions = self.postProcess(
                        generator: generator, output: output, tokens: tokens, partial: partial)
                    self.cache[key] = (Date(), suggestions)
                    results += Self.matching(suggestions, query: partial.text)
                }
            }
        }
        group.notify(queue: .main) {
            completion(results)
        }
    }

    private func retargeted(_ suggestions: [Suggestion], partial: Token) -> [Suggestion] {
        suggestions.map { s in
            var copy = s
            copy.deleteCount = partial.typedLength
            return copy
        }
    }

    private func scriptString(of generator: JSValue, tokens: [String]) -> String? {
        guard let script = generator.objectForKeyedSubscript("script"),
              !script.isUndefined, !script.isNull
        else { return nil }
        if script.isString { return script.toString() }
        if script.isArray {
            let parts = (0..<Int(script.toArray()?.count ?? 0)).compactMap { i -> String? in
                let element = script.atIndex(i)
                return element?.isString == true ? element?.toString() : nil
            }
            return parts.isEmpty ? nil : parts.map(TemplateResolver.shellEscaped).joined(separator: " ")
        }
        // Function-form scripts receive the token array and return a string/array.
        if isFunction(script) {
            let jsTokens = JSValue(object: tokens, in: script.context)
            guard let result = script.call(withArguments: [jsTokens as Any]) else { return nil }
            if result.isString { return result.toString() }
            if result.isArray {
                let parts = (0..<Int(result.toArray()?.count ?? 0)).compactMap { i -> String? in
                    let element = result.atIndex(i)
                    return element?.isString == true ? element?.toString() : nil
                }
                return parts.isEmpty ? nil : parts.map(TemplateResolver.shellEscaped).joined(separator: " ")
            }
        }
        return nil
    }

    private func postProcess(generator: JSValue, output: String, tokens: [String],
                             partial: Token) -> [Suggestion] {
        if let fn = generator.objectForKeyedSubscript("postProcess"), isFunction(fn) {
            let jsTokens = JSValue(object: tokens, in: fn.context)
            guard let value = fn.call(withArguments: [output, jsTokens as Any]),
                  value.isArray
            else { return [] }
            var suggestions: [Suggestion] = []
            for i in 0..<Int(value.toArray()?.count ?? 0) {
                guard let element = value.atIndex(i) else { continue }
                if element.isString {
                    suggestions.append(makeSuggestion(element.toString(), detail: "",
                                                      insertValue: nil, partial: partial))
                } else if element.isObject {
                    let node = SpecNode(element)
                    let name = node.primaryName
                    guard !name.isEmpty else { continue }
                    suggestions.append(makeSuggestion(name, detail: node.specDescription,
                                                      insertValue: node.insertValue,
                                                      partial: partial))
                }
            }
            return suggestions
        }
        let splitter: String = {
            guard let splitOn = generator.objectForKeyedSubscript("splitOn"),
                  splitOn.isString else { return "\n" }
            return splitOn.toString()
        }()
        return output.components(separatedBy: splitter)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { makeSuggestion($0, detail: "", insertValue: nil, partial: partial) }
    }

    private func makeSuggestion(_ name: String, detail: String, insertValue: String?,
                                partial: Token) -> Suggestion {
        let insert = insertValue.map(CompletionParser.stripCursorMark)
            ?? TemplateResolver.shellEscaped(name) + " "
        return Suggestion(display: name, insertText: insert,
                          deleteCount: partial.typedLength, detail: detail, kind: .argument)
    }

    // MARK: - Custom generators (fig's filepaths() and friends)

    /* `custom(tokens, executeShellCommand, context)` is an async JS function
       returning suggestions; executeShellCommand({command, args, cwd}) must
       hand back a Promise of {stdout, stderr, status}. Two conventions
       around it: getQueryTerm(token) names the part of the token the
       suggestions replace (for paths, everything after the last "/"), and
       trigger(newToken, oldToken) says when a fresh run is needed (the
       directory changed) — otherwise the last result is reused. */
    private struct CustomCacheKey: Hashable {
        let sid: String
        let cwd: String
        let prefixTokens: [String]
    }
    private var customCache: [CustomCacheKey: (token: String, suggestions: [Suggestion])] = [:]

    private func runCustom(generator: JSValue, custom: JSValue, tokens: [String], partial: Token,
                           cwd: String, sid: String,
                           completion: @escaping ([Suggestion]) -> Void) {
        guard let context = custom.context else { return completion([]) }
        let query = queryTerm(of: generator, token: partial.text)
        let deleteCount = query.count
        let cacheKey = CustomCacheKey(sid: sid, cwd: cwd, prefixTokens: Array(tokens.dropLast()))

        if let cached = customCache[cacheKey],
           let trigger = generator.objectForKeyedSubscript("trigger"), isFunction(trigger),
           trigger.call(withArguments: [partial.text, cached.token])?.toBool() == false {
            completion(Self.matching(retargeted(cached.suggestions, deleteCount: deleteCount),
                                     query: query))
            return
        }

        let exec = Self.makeExecuteShellCommand(in: context, defaultCWD: cwd)
        let generatorContext: [String: Any] = [
            "currentWorkingDirectory": cwd,
            "currentProcess": "zsh",
            "sshPrefix": "",
            // The whole token being typed (fig derives the directory from
            // it); the query term is only what the suggestions replace.
            "searchTerm": partial.text,
            "environmentVariables": ProcessInfo.processInfo.environment,
        ]
        guard let result = custom.call(withArguments: [tokens, exec, generatorContext]) else {
            return completion([])
        }

        let finish: (JSValue) -> Void = { [weak self] value in
            guard let self else { return completion([]) }
            let suggestions = self.customSuggestions(from: value, deleteCount: deleteCount)
            self.customCache[cacheKey] = (partial.text, suggestions)
            completion(Self.matching(suggestions, query: query))
        }
        if let then = result.objectForKeyedSubscript("then"), isFunction(then) {
            let onFulfilled: @convention(block) (JSValue) -> Void = { finish($0) }
            let onRejected: @convention(block) (JSValue) -> Void = { _ in completion([]) }
            // invokeMethod keeps `this` bound to the promise; a bare call
            // would run `then` with no receiver ("|this| is not a Promise").
            result.invokeMethod("then", withArguments: [
                JSValue(object: onFulfilled, in: context) as Any,
                JSValue(object: onRejected, in: context) as Any,
            ])
        } else {
            finish(result)
        }
    }

    private func queryTerm(of generator: JSValue, token: String) -> String {
        guard let fn = generator.objectForKeyedSubscript("getQueryTerm"), isFunction(fn),
              let value = fn.call(withArguments: [token]), value.isString
        else { return token }
        return value.toString() ?? token
    }

    /// Suggestions from a custom generator: {name|displayName, description,
    /// insertValue, type}. Folders keep their trailing "/" and take no space
    /// so the user can keep descending; everything else gets the usual space.
    private func customSuggestions(from value: JSValue, deleteCount: Int) -> [Suggestion] {
        guard value.isArray else { return [] }
        var suggestions: [Suggestion] = []
        for i in 0..<Int(value.toArray()?.count ?? 0) {
            guard let element = value.atIndex(i) else { continue }
            if element.isString {
                let name = element.toString() ?? ""
                suggestions.append(Suggestion(
                    display: name, insertText: TemplateResolver.shellEscaped(name) + " ",
                    deleteCount: deleteCount, detail: "", kind: .argument))
                continue
            }
            guard element.isObject else { continue }
            let node = SpecNode(element)
            let name = node.primaryName
            guard !name.isEmpty else { continue }
            let type = element.objectForKeyedSubscript("type")?.toString() ?? ""
            let isFolder = type == "folder" || name.hasSuffix("/")
            let kind: Suggestion.Kind = isFolder ? .folder : (type == "file" ? .file : .argument)
            let insert = node.insertValue.map(CompletionParser.stripCursorMark)
                ?? TemplateResolver.shellEscaped(name) + (isFolder ? "" : " ")
            suggestions.append(Suggestion(
                display: name, insertText: insert, deleteCount: deleteCount,
                detail: node.specDescription, kind: kind, priority: node.priority))
        }
        return suggestions
    }

    private func retargeted(_ suggestions: [Suggestion], deleteCount: Int) -> [Suggestion] {
        suggestions.map { s in
            var copy = s
            copy.deleteCount = deleteCount
            return copy
        }
    }

    /// Case-insensitive prefix filter on the display name; an empty query
    /// keeps everything except dotfiles.
    static func matching(_ suggestions: [Suggestion], query: String) -> [Suggestion] {
        suggestions.filter { s in
            if query.isEmpty { return !s.display.hasPrefix(".") }
            return s.display.lowercased().hasPrefix(query.lowercased())
        }
    }

    /// The `executeShellCommand` a custom generator receives: accepts the
    /// modern {command, args, cwd, env} form and the legacy command string,
    /// runs it off the main thread, and resolves a Promise with
    /// {stdout, stderr, status} (or the plain stdout string for legacy).
    private static func makeExecuteShellCommand(in context: JSContext, defaultCWD: String) -> JSValue {
        let block: @convention(block) (JSValue) -> JSValue = { request in
            JSValue(newPromiseIn: context) { resolve, _ in
                var script: String
                var cwd = defaultCWD
                var legacy = false
                if request.isString {
                    script = request.toString() ?? ""
                    legacy = true
                } else {
                    let command = request.objectForKeyedSubscript("command")?.toString() ?? ""
                    var parts = [command]
                    if let args = request.objectForKeyedSubscript("args"), args.isArray {
                        for i in 0..<Int(args.toArray()?.count ?? 0) {
                            if let a = args.atIndex(i), a.isString, let text = a.toString() {
                                parts.append(TemplateResolver.shellEscaped(text))
                            }
                        }
                    }
                    script = parts.joined(separator: " ")
                    if let dir = request.objectForKeyedSubscript("cwd"), dir.isString,
                       let path = dir.toString(), !path.isEmpty {
                        cwd = path
                    }
                }
                if ProcessInfo.processInfo.environment["SILL_DEBUG_EXEC"] != nil {
                    NSLog("Sill exec: %@  (cwd %@)", script, cwd)
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let output = runShell(script, cwd: cwd) ?? ""
                    DispatchQueue.main.async {
                        if legacy {
                            resolve?.call(withArguments: [output])
                        } else {
                            resolve?.call(withArguments: [
                                ["stdout": output, "stderr": "", "status": 0] as [String: Any]
                            ])
                        }
                    }
                }
            }
        }
        return JSValue(object: block, in: context)
    }

    private func isFunction(_ value: JSValue) -> Bool {
        guard !value.isUndefined, !value.isNull, value.isObject else { return false }
        return value.isInstance(of: value.context.objectForKeyedSubscript("Function"))
    }

    /// 3-second, 1MB-capped zsh run. Login shell so PATH matches the user's.
    private static func runShell(_ script: String, cwd: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", script]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let deadline = DispatchTime.now() + 3
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        var data = Data()
        let reader = DispatchQueue(label: "sill.generator.read")
        reader.sync {
            // Read incrementally so a chatty script can't fill the pipe.
            while true {
                let chunk = stdout.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
                if data.count > 1 << 20 { process.terminate(); break }
            }
        }
        if done.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
