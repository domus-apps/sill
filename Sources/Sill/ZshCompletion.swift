import Foundation

/* Definitions read out of zsh's own completion files, for commands Sill
   can't ask. A shell script is never run for --help (DerivedSpecStore), but
   a package often installs a `_name` file beside it (Homebrew links them
   into <prefix>/share/zsh/site-functions), and that file lists the
   subcommands and options with their descriptions.

   The file is shell code and is only ever read, never sourced. What can be
   understood without running it is the common hand-written shape: arrays of
   'name:description' handed to _describe, _arguments specs
   ('--dry-run[Preview]', '*:path:_files'), and `case` on the word being
   completed ("$words[2]", $line[1], $state) to tell which subcommand a call
   belongs to. Helper functions defined in the file are followed when
   called. Whatever is computed at completion time (cobra's `__complete`, a
   list built by running the program) is beyond reading and left out. */
enum ZshCompletion {
    /// The completion file for `command`, from the site-functions folder
    /// beside the bin it was found in (or beside the file it links to):
    /// `_<command>`, or the file whose `#compdef` line names it (`_mole`
    /// covers `mo`).
    static func file(for command: String, executable: URL) -> URL? {
        let fm = FileManager.default
        var folders: [String] = []
        for bin in [executable.deletingLastPathComponent(),
                    executable.resolvingSymlinksInPath().deletingLastPathComponent()] {
            let folder = bin.deletingLastPathComponent()
                .appendingPathComponent("share/zsh/site-functions").path
            if !folders.contains(folder), fm.fileExists(atPath: folder) { folders.append(folder) }
        }
        for folder in folders where fm.fileExists(atPath: folder + "/_" + command) {
            return URL(fileURLWithPath: folder + "/_" + command)
        }
        for folder in folders {
            let entries = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).sorted()
            for entry in entries where entry.hasPrefix("_") {
                let path = folder + "/" + entry
                if compdefNames(firstLine(of: path)).contains(command) {
                    return URL(fileURLWithPath: path)
                }
            }
        }
        return nil
    }

    /// The commands a `#compdef` line names: `#compdef mole mo` → both.
    /// Patterns (-p, -P) and key bindings (-k, -K) end the list.
    static func compdefNames(_ line: String) -> [String] {
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard words.first == "#compdef" else { return [] }
        var names: [String] = []
        for word in words.dropFirst() {
            if ["-p", "-P", "-k", "-K"].contains(word) { break }
            if word.hasPrefix("-") { continue }
            if let name = word.split(separator: "=").first { names.append(String(name)) }
        }
        return names
    }

    private static func firstLine(of path: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: path),
              let head = try? handle.read(upToCount: 512)
        else { return "" }
        try? handle.close()
        return String(decoding: head, as: UTF8.self)
            .split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    }

    /// The Fig-shaped spec `source` describes, or nil when nothing in it
    /// could be read. `fileName` (`_mole`) names the function zsh would call.
    static func spec(_ source: String, command: String, fileName: String) -> [String: Any]? {
        let reader = Reader(tokens: tokens(source), command: command)
        reader.run(0..<reader.tokens.count, Context(), depth: 0)
        // An autoloaded file usually just defines the function; zsh calls it.
        let mains = reader.registered + [fileName]
        if !mains.contains(where: reader.called.contains),
           let main = mains.first(where: { reader.functions[$0] != nil }) {
            reader.call(main, Context(), depth: 0)
        }
        let root = reader.root
        guard !root.subcommands.isEmpty || !root.options.isEmpty || !root.args.isEmpty
        else { return nil }
        return root.figObject(isRoot: true)
    }

    // MARK: - Words

    struct Word {
        struct Segment {
            var text: String
            /// Quoted or escaped: never brace-expanded.
            var quoted: Bool
        }

        var segments: [Segment] = []
        /// Holds a parameter or command substitution, so its value isn't
        /// known without running anything.
        var expands = false
        var value: String { segments.map(\.text).joined() }

        /// The words zsh's brace expansion makes of this one:
        /// '(-h --help)'{-h,--help}'[Show help]' is two specs.
        var expanded: [String] {
            var results = [""]
            for segment in segments {
                let pieces = segment.quoted ? [[segment.text]] : Self.braces(segment.text)
                for alternatives in pieces {
                    results = results.flatMap { prefix in alternatives.map { prefix + $0 } }
                    if results.count > 64 { return [value] }
                }
            }
            return results
        }

        /// Unquoted text as a run of literal parts and `{a,b}` choices.
        private static func braces(_ text: String) -> [[String]] {
            var pieces: [[String]] = []
            var literal = ""
            var rest = Substring(text)
            while let open = rest.firstIndex(of: "{") {
                guard let close = rest[open...].firstIndex(of: "}") else { break }
                let inner = rest[rest.index(after: open)..<close]
                literal += rest[..<open]
                if inner.contains(",") {
                    pieces.append([literal])
                    literal = ""
                    pieces.append(inner.split(separator: ",", omittingEmptySubsequences: false).map(String.init))
                } else {
                    literal += rest[open...close]
                }
                rest = rest[rest.index(after: close)...]
            }
            pieces.append([literal + rest])
            return pieces
        }
    }

    enum Token {
        case word(Word)
        /// Separators and grouping: "\n" ";" ";;" "&&" "||" "|" "&" "(" ")"
        /// "{" "}", and "((" for a whole arithmetic expression.
        case op(String)
    }

    static func tokens(_ source: String) -> [Token] {
        let c = Array(source)
        var i = 0
        var out: [Token] = []
        func isBlank(_ ch: Character?) -> Bool {
            guard let ch else { return true }
            return ch == " " || ch == "\t" || ch.isNewline || ch == ";"
        }
        while i < c.count {
            let ch = c[i]
            let next: Character? = i + 1 < c.count ? c[i + 1] : nil
            if ch == " " || ch == "\t" { i += 1; continue }
            if ch == "\\", next?.isNewline == true { i += 2; continue }
            if ch.isNewline { out.append(.op("\n")); i += 1; continue }
            if ch == "#" {
                while i < c.count, !c[i].isNewline { i += 1 }
                continue
            }
            if ch == ";" {
                if let next, next == ";" || next == "&" || next == "|" {
                    out.append(.op(String([ch, next])))
                    i += 2
                } else {
                    out.append(.op(";"))
                    i += 1
                }
                continue
            }
            if ch == "&" || ch == "|" {
                if next == ch {
                    out.append(.op(String([ch, ch])))
                    i += 2
                } else {
                    out.append(.op(String(ch)))
                    i += 1
                }
                continue
            }
            if ch == "(" {
                if next == "(" {
                    i = skipBalanced(c, from: i, open: "(", close: ")")
                    out.append(.op("(("))
                } else {
                    out.append(.op("("))
                    i += 1
                }
                continue
            }
            if ch == ")" { out.append(.op(")")); i += 1; continue }
            if ch == "{" || ch == "}", isBlank(next) {
                out.append(.op(String(ch)))
                i += 1
                continue
            }

            var word = Word()
            var plain = ""
            func flush() {
                if !plain.isEmpty { word.segments.append(.init(text: plain, quoted: false)) }
                plain = ""
            }
            scanning: while i < c.count {
                let ch = c[i]
                if ch == " " || ch == "\t" || ch.isNewline || ";&|()".contains(ch) { break scanning }
                switch ch {
                case "\\":
                    if i + 1 < c.count, !c[i + 1].isNewline {
                        flush()
                        word.segments.append(.init(text: String(c[i + 1]), quoted: true))
                    }
                    i += 2
                case "'":
                    flush()
                    var text = ""
                    i += 1
                    while i < c.count, c[i] != "'" { text.append(c[i]); i += 1 }
                    i += 1
                    word.segments.append(.init(text: text, quoted: true))
                case "\"":
                    flush()
                    var text = ""
                    i += 1
                    while i < c.count, c[i] != "\"" {
                        if c[i] == "\\", i + 1 < c.count {
                            if c[i + 1].isNewline { i += 2; continue }
                            if "\"\\$`".contains(c[i + 1]) { text.append(c[i + 1]); i += 2; continue }
                        }
                        if c[i] == "$" || c[i] == "`" { word.expands = true }
                        text.append(c[i])
                        i += 1
                    }
                    i += 1
                    word.segments.append(.init(text: text, quoted: true))
                case "$" where i + 1 < c.count && c[i + 1] == "'":
                    // $'…', with the escapes completion files use.
                    flush()
                    var text = ""
                    i += 2
                    while i < c.count, c[i] != "'" {
                        if c[i] == "\\", i + 1 < c.count {
                            switch c[i + 1] {
                            case "n": text.append("\n")
                            case "t": text.append("\t")
                            default: text.append(c[i + 1])
                            }
                            i += 2
                            continue
                        }
                        text.append(c[i])
                        i += 1
                    }
                    i += 1
                    word.segments.append(.init(text: text, quoted: true))
                case "$":
                    word.expands = true
                    if i + 1 < c.count, c[i + 1] == "(" || c[i + 1] == "{" {
                        let end = skipBalanced(c, from: i + 1, open: c[i + 1],
                                               close: c[i + 1] == "(" ? ")" : "}")
                        plain += String(c[i..<end])
                        i = end
                    } else {
                        plain.append(ch)
                        i += 1
                    }
                case "`":
                    word.expands = true
                    var j = i + 1
                    while j < c.count, c[j] != "`" { j += 1 }
                    plain += String(c[i..<min(j + 1, c.count)])
                    i = j + 1
                default:
                    plain.append(ch)
                    i += 1
                }
            }
            flush()
            out.append(.word(word))
        }
        return out
    }

    /// The index just past the bracket matching the one at `start`.
    private static func skipBalanced(_ c: [Character], from start: Int,
                                     open: Character, close: Character) -> Int {
        var depth = 0
        var i = start
        while i < c.count {
            if c[i] == "'" {
                i += 1
                while i < c.count, c[i] != "'" { i += 1 }
            } else if c[i] == "\\" {
                i += 1
            } else if c[i] == open {
                depth += 1
            } else if c[i] == close {
                depth -= 1
                if depth == 0 { return i + 1 }
            }
            i += 1
        }
        return c.count
    }

    // MARK: - Reading

    /// Where a call's findings go: the subcommand path it completes, or
    /// nowhere (a branch for an option's value, a glob pattern, a `case` on
    /// something other than the word being completed).
    struct Context {
        var path: [[String]] = []
        var ignored = false
    }

    private struct Frame {
        enum Subject { case word(Int), line, state, other }
        var subject: Subject
        var patterns: [String] = []
        var expectingPattern = true
    }

    private final class Node {
        var names: [String]
        var description = ""
        var subcommands: [Node] = []
        var options: [Option] = []
        var args: [[String: Any]] = []

        init(names: [String]) { self.names = names }

        /// The subcommand `patterns` name, made if missing; extra patterns
        /// (`analyze|analyse)`) become its aliases.
        func child(_ patterns: [String]) -> Node {
            if let found = subcommands.first(where: { !Set($0.names).isDisjoint(with: patterns) }) {
                for name in patterns where !found.names.contains(name) { found.names.append(name) }
                return found
            }
            let node = Node(names: patterns)
            subcommands.append(node)
            return node
        }

        func figObject(isRoot: Bool) -> [String: Any] {
            var object: [String: Any] = ["name": isRoot ? names[0] as Any : names as Any]
            if !description.isEmpty { object["description"] = description }
            if !subcommands.isEmpty {
                object["subcommands"] = subcommands.prefix(500).map { $0.figObject(isRoot: false) }
            }
            if !options.isEmpty {
                object["options"] = Self.merged(options).prefix(500).map(\.figObject)
            }
            if !args.isEmpty { object["args"] = args }
            return object
        }

        /// `-n` and `--dry-run` listed apart with one description are one
        /// option with two names.
        private static func merged(_ options: [Option]) -> [Option] {
            var result: [Option] = []
            for option in options {
                if !option.description.isEmpty,
                   let index = result.firstIndex(where: {
                       $0.description == option.description && ($0.arg == nil) == (option.arg == nil)
                   }) {
                    result[index].names += option.names.filter { !result[index].names.contains($0) }
                } else {
                    result.append(option)
                }
            }
            return result
        }
    }

    private struct Option {
        var names: [String]
        var description: String
        var arg: [String: Any]?
        var repeatable: Bool

        var figObject: [String: Any] {
            var object: [String: Any] = ["name": names]
            if !description.isEmpty { object["description"] = description }
            if let arg { object["args"] = arg }
            if repeatable { object["isRepeatable"] = true }
            return object
        }
    }

    private enum Action {
        case none, files, folders, other
        case values([(name: String, description: String)])
        case function(String)
        case state(String)
    }

    private struct Argument {
        var message: String
        var optional: Bool
        var action: Action
    }

    private enum Spec {
        case option(names: [String], description: String, argument: Argument?, repeatable: Bool)
        case positional(variadic: Bool, argument: Argument)
    }

    private final class Reader {
        let tokens: [Token]
        let root: Node
        /// Function name → its body's token range.
        var functions: [String: Range<Int>] = [:]
        /// Start of a function definition → the index just past it.
        var definitions: [Int: Int] = [:]
        var arrays: [String: [String]] = [:]
        /// State name → whether an option's value declared it (`->style`).
        var stateIsOptionValue: [String: Bool] = [:]
        /// Functions `compdef` registers (`compdef _mole mole mo`).
        var registered: [String] = []
        var called: Set<String> = []
        private var active: Set<String> = []
        private var calls = 0

        init(tokens: [Token], command: String) {
            self.tokens = tokens
            root = Node(names: [command])
            findFunctions()
        }

        /// `name() { … }` and `function name { … }`, at any depth.
        private func findFunctions() {
            var i = 0
            while i < tokens.count {
                var nameIndex: Int?
                var braceSearch = i
                if case .word(let w) = tokens[i], !w.expands {
                    if w.value == "function", i + 1 < tokens.count, case .word = tokens[i + 1] {
                        nameIndex = i + 1
                        braceSearch = i + 2
                        if isOp(braceSearch, "("), isOp(braceSearch + 1, ")") { braceSearch += 2 }
                    } else if isOp(i + 1, "("), isOp(i + 2, ")") {
                        nameIndex = i
                        braceSearch = i + 3
                    }
                }
                guard let nameIndex, case .word(let name) = tokens[nameIndex] else { i += 1; continue }
                while isOp(braceSearch, "\n") { braceSearch += 1 }
                guard isOp(braceSearch, "{") else { i += 1; continue }
                var depth = 0
                var j = braceSearch
                while j < tokens.count {
                    if isOp(j, "{") { depth += 1 }
                    if isOp(j, "}") {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    j += 1
                }
                functions[name.value] = (braceSearch + 1)..<min(j, tokens.count)
                definitions[i] = min(j + 1, tokens.count)
                i = braceSearch + 1
            }
        }

        private func isOp(_ index: Int, _ op: String) -> Bool {
            guard index < tokens.count, case .op(let found) = tokens[index] else { return false }
            return found == op
        }

        func call(_ name: String, _ context: Context, depth: Int) {
            guard let body = functions[name], depth < 8, calls < 500, !active.contains(name)
            else { return }
            calls += 1
            called.insert(name)
            active.insert(name)
            run(body, context, depth: depth + 1)
            active.remove(name)
        }

        func run(_ range: Range<Int>, _ base: Context, depth: Int) {
            var frames: [Frame] = []
            var command: [Word] = []
            var patterns: [String] = []
            var i = range.lowerBound

            func context() -> Context {
                var context = base
                for frame in frames where !frame.expectingPattern {
                    let literal = !frame.patterns.isEmpty && frame.patterns.allSatisfy(Self.isName)
                    switch frame.subject {
                    case .state:
                        if frame.patterns.contains(where: { stateIsOptionValue[$0] == true }) {
                            context.ignored = true
                        }
                    case .word(let n):
                        guard literal, n - 2 <= context.path.count else { context.ignored = true; continue }
                        context.path = Array(context.path.prefix(n - 2)) + [frame.patterns]
                    case .line:
                        guard literal else { context.ignored = true; continue }
                        context.path.append(frame.patterns)
                    case .other:
                        context.ignored = true
                    }
                }
                return context
            }
            func finish() {
                if !command.isEmpty { perform(command, context(), depth: depth) }
                command = []
            }

            while i < range.upperBound {
                if let end = definitions[i] {
                    finish()
                    i = end
                    continue
                }
                let expectingPattern = frames.last?.expectingPattern == true
                switch tokens[i] {
                case .word(let word):
                    if expectingPattern {
                        if word.value == "esac", patterns.isEmpty {
                            frames.removeLast()
                        } else {
                            patterns.append(word.expands ? "*" : word.value)
                        }
                    } else if command.allSatisfy({ Self.keywords.contains($0.value) }), word.value == "case" {
                        command = []
                        var j = i + 1
                        guard j < range.upperBound, case .word(let subject) = tokens[j] else { i += 1; continue }
                        j += 1
                        while j < range.upperBound, isOp(j, "\n") { j += 1 }
                        if j < range.upperBound, case .word(let keyword) = tokens[j], keyword.value == "in" {
                            j += 1
                        }
                        frames.append(Frame(subject: Self.subject(subject.value)))
                        patterns = []
                        i = j
                        continue
                    } else if command.allSatisfy({ Self.keywords.contains($0.value) }), word.value == "esac" {
                        command = []
                        if !frames.isEmpty { frames.removeLast() }
                    } else {
                        command.append(word)
                    }
                case .op(let op):
                    switch op {
                    case ";;", ";&", ";|":
                        finish()
                        if !frames.isEmpty {
                            frames[frames.count - 1].expectingPattern = true
                            frames[frames.count - 1].patterns = []
                        }
                        patterns = []
                    case "(":
                        if !expectingPattern, let last = command.last, !last.expands,
                           last.value.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\+?=$"#, options: .regularExpression) != nil {
                            command.removeLast()
                            let (items, end) = arrayLiteral(from: i + 1, upTo: range.upperBound)
                            var name = String(last.value.dropLast())
                            if name.hasSuffix("+") {
                                name.removeLast()
                                arrays[name, default: []] += items
                            } else {
                                arrays[name] = items
                            }
                            i = end
                            continue
                        }
                        if !expectingPattern { finish() }
                    case ")":
                        if expectingPattern {
                            frames[frames.count - 1].patterns = patterns
                            frames[frames.count - 1].expectingPattern = false
                            patterns = []
                        } else {
                            finish()
                        }
                    case "|", "\n":
                        if !expectingPattern { finish() }
                    default:
                        finish()
                    }
                }
                i += 1
            }
            finish()
        }

        /// The words of `( … )` and the index just past its `)`.
        private func arrayLiteral(from start: Int, upTo end: Int) -> ([String], Int) {
            var items: [String] = []
            var i = start
            while i < end {
                if isOp(i, ")") { return (items, i + 1) }
                if case .word(let word) = tokens[i], !word.expands { items += word.expanded }
                i += 1
            }
            return (items, end)
        }

        private static let keywords: Set<String> = [
            "if", "then", "else", "elif", "fi", "do", "done", "while", "until", "!", "time",
            "noglob", "builtin", "command", "nocorrect", "{", "}",
        ]

        private func perform(_ words: [Word], _ context: Context, depth: Int) {
            var words = words[...]
            while let first = words.first,
                  Self.keywords.contains(first.value) || Self.isAssignment(first) {
                words = words.dropFirst()
            }
            guard let first = words.first, !first.expands else { return }
            let rest = Array(words.dropFirst())
            switch first.value {
            case "_describe": describe(rest, context)
            case "_arguments": arguments(rest, context, depth: depth)
            case "compdef":
                if let function = rest.first(where: { !$0.value.hasPrefix("-") }) {
                    registered.append(function.value)
                }
            default:
                if functions[first.value] != nil { call(first.value, context, depth: depth) }
            }
        }

        // MARK: _describe

        /// `_describe [-t tag] 'descr' array [opts…] [-- 'descr' array …]`:
        /// each array of 'name:description' lists subcommands here.
        private func describe(_ words: [Word], _ context: Context) {
            guard !context.ignored else { return }
            var i = 0
            var expectingDescription = true
            var entries: [(String, String)] = []
            while i < words.count {
                let value = words[i].value
                if value == "--" {
                    expectingDescription = true
                } else if expectingDescription {
                    if value == "-t" {
                        i += 1
                    } else if !(value.hasPrefix("-") && value.count > 1) {
                        if i + 1 < words.count {
                            entries += (arrays[words[i + 1].value] ?? []).map(Self.nameAndDescription)
                        }
                        i += 1
                        expectingDescription = false
                    }
                }
                i += 1
            }
            let node = self.node(at: context.path)
            for (name, description) in entries where Self.isName(name) {
                let child = node.child([name])
                if child.description.isEmpty { child.description = description }
            }
        }

        private static func nameAndDescription(_ item: String) -> (String, String) {
            var name = ""
            var rest = Substring(item)
            while let ch = rest.first {
                rest = rest.dropFirst()
                if ch == "\\", let escaped = rest.first {
                    name.append(escaped)
                    rest = rest.dropFirst()
                } else if ch == ":" {
                    return (name, rest.replacingOccurrences(of: "\\:", with: ":"))
                } else {
                    name.append(ch)
                }
            }
            return (name, "")
        }

        // MARK: _arguments

        private func arguments(_ words: [Word], _ context: Context, depth: Int) {
            guard !context.ignored else { return }
            var i = 0
            // _arguments' own flags come first: -s -S -C, -A pat, -O name, `:`
            // (clap passes them in an array: "${_arguments_options[@]}").
            while i < words.count {
                let value = words[i].value
                if words[i].expands {
                    guard let items = referenced(words[i]), !items.allSatisfy(Self.isArgumentsFlag)
                    else { i += 1; continue }
                    break
                } else if value == ":" {
                    i += 1
                    break
                } else if ["-A", "-O", "-M"].contains(value) {
                    i += 2
                } else if Self.isArgumentsFlag(value) {
                    i += 1
                } else {
                    break
                }
            }
            let node = self.node(at: context.path)
            for word in words.dropFirst(i) {
                // Specs kept in an array: `_arguments -s -S : $args` (ripgrep).
                let texts = word.expands ? referenced(word) ?? [] : word.expanded
                for text in texts {
                    guard let spec = parse(text) else { continue }
                    switch spec {
                    case .option(let names, let description, let argument, let repeatable):
                        if case .state(let state)? = argument?.action { stateIsOptionValue[state] = true }
                        guard !node.options.contains(where: { !Set($0.names).isDisjoint(with: names) })
                        else { continue }
                        node.options.append(Option(names: names, description: description,
                                                   arg: argument.map { figArg($0, variadic: false) },
                                                   repeatable: repeatable))
                    case .positional(let variadic, let argument):
                        switch argument.action {
                        case .function(let name):
                            call(name, context, depth: depth)
                        case .state(let state):
                            if stateIsOptionValue[state] == nil { stateIsOptionValue[state] = false }
                        case .files, .folders, .values:
                            let arg = figArg(argument, variadic: variadic)
                            if !node.args.contains(where: { $0["name"] as? String == arg["name"] as? String }) {
                                node.args.append(arg)
                            }
                        case .none, .other:
                            break
                        }
                    }
                }
            }
        }

        private func figArg(_ argument: Argument, variadic: Bool) -> [String: Any] {
            let message = argument.message.trimmingCharacters(in: .whitespaces)
            var object: [String: Any] = ["name": message.isEmpty ? "value" : message]
            switch argument.action {
            case .files: object["template"] = "filepaths"
            case .folders: object["template"] = "folders"
            case .values(let values):
                object["suggestions"] = values.map { value -> [String: Any] in
                    value.description.isEmpty
                        ? ["name": value.name]
                        : ["name": value.name, "description": value.description]
                }
            default: break
            }
            if argument.optional { object["isOptional"] = true }
            if variadic { object["isVariadic"] = true }
            return object
        }

        /// One _arguments spec:
        /// `[(exclusions)][*]-name[=|+|-][description][:message:action]`
        /// for an option, `[N|*]:message:action` for a positional.
        private func parse(_ text: String) -> Spec? {
            var s = Substring(text)
            if s.hasPrefix("(") {
                guard let close = s.firstIndex(of: ")") else { return nil }
                s = s[s.index(after: close)...]
            }
            var repeatable = false
            if s.hasPrefix("*") {
                repeatable = true
                s = s.dropFirst()
            }
            guard let first = s.first else { return nil }
            if first == "-" || first == "+", s.count > 1 {
                var name = String(first)
                s = s.dropFirst()
                while let ch = s.first, !"[:=+".contains(ch) {
                    name.append(ch)
                    s = s.dropFirst()
                }
                if s.hasPrefix("=-") { s = s.dropFirst(2) } else if s.hasPrefix("=") || s.hasPrefix("+") { s = s.dropFirst() }
                if name.count > 2, name.hasSuffix("-"), !name.hasPrefix("--") { name.removeLast() }
                guard name.count >= 2, !name.contains(" "), name != "--" else { return nil }
                var description = ""
                if s.hasPrefix("[") {
                    s = s.dropFirst()
                    while let ch = s.first, ch != "]" {
                        s = s.dropFirst()
                        if ch == "\\", let escaped = s.first {
                            description.append(escaped)
                            s = s.dropFirst()
                        } else {
                            description.append(ch)
                        }
                    }
                    s = s.dropFirst()
                }
                var argument: Argument?
                if s.hasPrefix(":") {
                    s = s.dropFirst()
                    let optional = s.hasPrefix(":")
                    if optional { s = s.dropFirst() }
                    let (message, action) = Self.messageAndAction(s)
                    argument = Argument(message: message, optional: optional, action: classify(action))
                }
                return .option(names: [name], description: description, argument: argument,
                               repeatable: repeatable)
            }
            if !repeatable { while let ch = s.first, ch.isNumber { s = s.dropFirst() } }
            guard s.hasPrefix(":") else { return nil }
            s = s.dropFirst()
            var optional = false
            if s.hasPrefix(":") {
                optional = true
                s = s.dropFirst()
                if s.hasPrefix(":") { s = s.dropFirst() }
            }
            let (message, action) = Self.messageAndAction(s)
            return .positional(variadic: repeatable,
                               argument: Argument(message: message, optional: optional, action: classify(action)))
        }

        private static func messageAndAction(_ s: Substring) -> (String, String) {
            var message = ""
            var rest = s
            while let ch = rest.first {
                rest = rest.dropFirst()
                if ch == "\\", let escaped = rest.first {
                    message.append(escaped)
                    rest = rest.dropFirst()
                } else if ch == ":" {
                    return (message, String(rest))
                } else {
                    message.append(ch)
                }
            }
            return (message, "")
        }

        private func classify(_ raw: String) -> Action {
            let action = raw.trimmingCharacters(in: .whitespaces)
            if action.isEmpty { return .none }
            if action.hasPrefix("->") {
                return .state(String(action.dropFirst(2).prefix { !$0.isWhitespace && $0 != ":" }))
            }
            if action.hasPrefix("((") {
                guard let close = action.range(of: "))") else { return .other }
                let inner = action[action.index(action.startIndex, offsetBy: 2)..<close.lowerBound]
                return .values(Self.items(inner).compactMap { item in
                    let (name, description) = Self.nameAndDescription(item)
                    return name.isEmpty ? nil : (name, description)
                })
            }
            if action.hasPrefix("(") {
                guard let close = action.firstIndex(of: ")") else { return .other }
                let inner = action[action.index(after: action.startIndex)..<close]
                return .values(Self.items(inner).map { ($0, "") })
            }
            let program = action.split(separator: " ").first.map(String.init) ?? ""
            switch program {
            case "_files", "_path_files": return action.contains("-/") ? .folders : .files
            case "_directories", "_cd": return .folders
            default: return functions[program] != nil ? .function(program) : .other
            }
        }

        /// Whitespace-separated items, with quotes and backslashes undone;
        /// `name\:description` comes out as `name:description`.
        private static func items(_ text: Substring) -> [String] {
            var items: [String] = []
            var current = ""
            var quote: Character?
            var rest = text
            while let ch = rest.first {
                rest = rest.dropFirst()
                if let open = quote {
                    if ch == open { quote = nil } else { current.append(ch) }
                } else if ch == "\"" || ch == "'" {
                    quote = ch
                } else if ch == "\\", let escaped = rest.first {
                    current.append(escaped)
                    rest = rest.dropFirst()
                } else if ch == " " || ch == "\t" || ch.isNewline {
                    if !current.isEmpty { items.append(current) }
                    current = ""
                } else {
                    current.append(ch)
                }
            }
            if !current.isEmpty { items.append(current) }
            return items
        }

        // MARK: Helpers

        private static func isArgumentsFlag(_ text: String) -> Bool {
            text.range(of: #"^-[sSCRwWn0]+$"#, options: .regularExpression) != nil
        }

        /// The items of the array a word is nothing but a reference to:
        /// `$args`, `${args}`, `"${args[@]}"`, `${(@)args}`.
        private func referenced(_ word: Word) -> [String]? {
            let pattern = #"^\$\{?(\(@\))?([A-Za-z_][A-Za-z0-9_]*)(\[[@*]\])?\}?$"#
            guard let match = word.value.range(of: pattern, options: .regularExpression),
                  match == word.value.startIndex..<word.value.endIndex
            else { return nil }
            let name = word.value.filter { $0.isLetter || $0.isNumber || $0 == "_" }
            return arrays[name]
        }

        private func node(at path: [[String]]) -> Node {
            path.reduce(root) { $0.child($1) }
        }

        /// A subcommand name, not a glob or anything computed.
        static func isName(_ text: String) -> Bool {
            text.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:+@-]*$"#, options: .regularExpression) != nil
        }

        private static func isAssignment(_ word: Word) -> Bool {
            word.value.range(of: #"^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?="#, options: .regularExpression) != nil
        }

        private static func subject(_ text: String) -> Frame.Subject {
            let bare = text.filter { $0 != "$" && $0 != "{" && $0 != "}" }
            if bare == "state" { return .state }
            if bare == "line[1]" { return .line }
            if bare.hasPrefix("words["), bare.hasSuffix("]"),
               let n = Int(bare.dropFirst(6).dropLast()), n >= 2 {
                return .word(n)
            }
            return .other
        }
    }
}
