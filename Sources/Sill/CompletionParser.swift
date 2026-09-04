import Foundation

/// One completion the popup can offer.
struct Suggestion: Equatable {
    enum Kind {
        case command, subcommand, option, argument, file, folder
    }

    var display: String
    /// What replaces the partial token when chosen.
    var insertText: String
    /// Characters before the caret to delete first (the partial token).
    var deleteCount: Int
    var detail: String
    var kind: Kind
    /// Other names for the same thing ("a" for add, "-m" for --message),
    /// shown dimly beside the display name.
    var aliases: [String] = []
    var priority: Int = 50
    /// Match quality, for ranking — FuzzyMatcher.Match.rank (tier first,
    /// then the fuzzy score).
    var score: Int = 0
    /// Characters of `display` the typed partial accounts for; the row
    /// highlights them so a fuzzy hit explains itself.
    var matchedOffsets: [Int] = []
}

extension Suggestion {
    /// True when the word before the caret already IS this suggestion:
    /// accepting it would replace those characters with themselves.
    func insertsNothing(before caretPrefix: String) -> Bool {
        deleteCount == insertText.count && caretPrefix.hasSuffix(insertText)
    }
}

/// A shell word with its position in the buffer.
struct Token: Equatable {
    var text: String
    /// Length of the token as typed, quotes and escapes included — what an
    /// insertion must delete to replace it.
    var typedLength: Int
    var isSeparator: Bool = false
}

enum Tokenizer {
    /// Splits the buffer up to the caret into shell words. Minimal on
    /// purpose: quotes and backslashes are honored, expansions are not —
    /// a wrong suggestion is cheap, a wrong parse of `"…"` is confusing.
    /// `|`, `;`, `&&`, `||`, `&` become separator tokens so the parser can
    /// complete the rightmost simple command.
    /// If the buffer ends in whitespace, a trailing empty token marks a
    /// fresh word under the caret.
    static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var text = ""
        var typed = 0
        var inWord = false
        var quote: Character? = nil

        func flush() {
            if inWord { tokens.append(Token(text: text, typedLength: typed)) }
            text = ""
            typed = 0
            inWord = false
        }

        var iterator = input.makeIterator()
        var lookahead: Character? = iterator.next()
        func advance() -> Character? {
            defer { lookahead = iterator.next() }
            return lookahead
        }

        while let ch = advance() {
            if let q = quote {
                typed += 1
                if ch == q {
                    quote = nil
                } else if ch == "\\", q == "\"", let next = lookahead,
                          next == "\"" || next == "\\" {
                    text.append(next)
                    typed += 1
                    _ = advance()
                } else {
                    text.append(ch)
                }
                continue
            }
            switch ch {
            case " ", "\t":
                flush()
            case "'", "\"":
                quote = ch
                inWord = true
                typed += 1
            case "\\":
                inWord = true
                typed += 1
                if let next = lookahead {
                    text.append(next)
                    typed += 1
                    _ = advance()
                }
            case "|", "&", ";":
                flush()
                var sep = String(ch)
                if (ch == "|" || ch == "&"), lookahead == ch {
                    sep.append(ch)
                    _ = advance()
                }
                tokens.append(Token(text: sep, typedLength: sep.count, isSeparator: true))
            default:
                inWord = true
                text.append(ch)
                typed += 1
            }
        }
        flush()
        if input.last == " " || input.last == "\t" || input.isEmpty {
            tokens.append(Token(text: "", typedLength: 0))
        }
        return tokens
    }
}

/// A positional-arg spec the caller must resolve asynchronously (file
/// templates natively, generators via the SpecEngine).
struct PendingArg {
    var node: SpecNode
    var partial: Token
}

struct CompletionResult {
    var suggestions: [Suggestion]
    /// Set when the current token is a positional/option arg whose values
    /// come from a template or generator.
    var pendingArg: PendingArg?
    /// The simple command's tokens, partial included — generator scripts and
    /// postProcess functions receive these.
    var commandTokens: [String] = []
    /// The first word of a command no spec covers, as typed — a candidate
    /// for learning from `--help` (DerivedSpecStore).
    var unknownCommand: String? = nil
    /// A learned spec's subcommand the user has reached whose own options
    /// haven't been read yet: root command name, then subcommand names.
    var unexploredPath: [String]? = nil
    /// Where in the spec tree the caret is: the command, then the
    /// subcommands walked — the level an overlay from `--help` attaches to.
    var path: [String] = []
}

/// What `--help` listed at one level of a command that has a spec, for the
/// parser to add whatever the spec lacks there (DerivedSpecStore).
struct OverlayLevel {
    struct Entry {
        var names: [String]
        var description: String
    }
    var subcommands: [Entry]
    var options: [Entry]

    init(subcommands: [Entry], options: [Entry]) {
        self.subcommands = subcommands
        self.options = options
    }

    /// From the Fig-shaped level object the store keeps.
    init(_ object: [String: Any]) {
        func entries(_ key: String) -> [Entry] {
            (object[key] as? [[String: Any]] ?? []).compactMap { item in
                let names: [String]
                if let name = item["name"] as? String { names = [name] }
                else { names = item["name"] as? [String] ?? [] }
                guard !names.isEmpty else { return nil }
                return Entry(names: names, description: item["description"] as? String ?? "")
            }
        }
        self.init(subcommands: entries("subcommands"), options: entries("options"))
    }
}

protocol OverlayProviding {
    func overlay(for path: [String]) -> OverlayLevel?
}

/* Walks a buffer prefix against a Fig spec tree and produces ranked
   suggestions. Pure logic apart from the JSValue-backed SpecNode reads —
   unit-testable with a small inline spec. */
struct CompletionParser {
    let engine: any SpecProviding
    /// Picks the user made before, per command — orders equal matches.
    var recency: RecencyStore? = nil
    /// Command names to offer while the first word is being typed.
    var commands: (any CommandCatalogProviding)? = nil
    /// Gaps in a spec, read from the command's own --help at each level.
    var overlays: (any OverlayProviding)? = nil

    /// The simple command under the caret: the rightmost command of a
    /// pipeline/list, minus leading environment assignments and wrappers
    /// (`sudo`, `env`, …), which change nothing about its completions.
    static func commandTokens(of prefix: String) -> [Token] {
        var tokens = Tokenizer.tokenize(prefix)
        if let lastSeparator = tokens.lastIndex(where: { $0.isSeparator }) {
            tokens = Array(tokens[(lastSeparator + 1)...])
        }
        let wrappers: Set<String> = ["sudo", "env", "command", "builtin", "nohup", "time", "exec"]
        while let first = tokens.first, tokens.count > 1,
              first.text.contains("=") || wrappers.contains(first.text) {
            tokens.removeFirst()
        }
        return tokens
    }

    func complete(buffer: String, cursor: Int, searchPath: String = "") -> CompletionResult {
        let prefix = String(buffer.prefix(cursor))
        var tokens = Self.commandTokens(of: prefix)

        if tokens.count == 1 {
            return commandName(tokens[0], searchPath: searchPath)
        }
        guard tokens.count >= 2 else { return CompletionResult(suggestions: []) }
        let commandName = (tokens[0].text as NSString).lastPathComponent
        guard let root = engine.spec(for: commandName) else {
            return CompletionResult(suggestions: [], unknownCommand: tokens[0].text)
        }

        let commandTokens = tokens.map(\.text)
        let partial = tokens.removeLast()
        var node = root
        var walked = [commandName]
        var argsOnly = false
        var argIndex = 0
        var pendingOptionArg: SpecNode?
        /// Stamps the fields every outcome shares.
        func finished(_ result: CompletionResult) -> CompletionResult {
            var result = result
            result.commandTokens = commandTokens
            result.unexploredPath = node.needsExploration ? walked : nil
            result.path = walked
            return result
        }

        for token in tokens.dropFirst() {
            if argsOnly {
                continue
            }
            if token.text == "--" {
                argsOnly = true
                pendingOptionArg = nil
                continue
            }
            if let pending = pendingOptionArg {
                _ = pending
                pendingOptionArg = nil
                continue
            }
            if token.text.hasPrefix("-"), token.text != "-" {
                let name = String(token.text.prefix(while: { $0 != "=" }))
                if let option = node.options.first(where: { $0.names.contains(name) }),
                   !token.text.contains("="),
                   let arg = option.args.first, !arg.isOptional {
                    pendingOptionArg = arg
                }
                continue
            }
            if argIndex == 0,
               let sub = node.subcommands.first(where: { $0.names.contains(token.text) }) {
                walked.append(sub.primaryName)
                // Big CLIs split subtrees into separate files ("aws/s3").
                if let name = sub.loadSpecName, let loaded = engine.spec(for: name) {
                    node = loaded
                } else {
                    node = sub
                }
                continue
            }
            // A positional argument. Variadic args absorb everything after.
            let positional = node.args
            if argIndex < positional.count, positional[argIndex].isVariadic {
                continue
            }
            argIndex += 1
        }

        // What can the partial token be?
        if let pending = pendingOptionArg {
            return finished(argSuggestions(for: pending, partial: partial, command: commandName))
        }
        if partial.text.hasPrefix("-"), !argsOnly {
            /* One row per option, named by the alias the partial matches
               (the long form when both do), with the others shown beside it. */
            let options = node.options.compactMap { option -> Suggestion? in
                guard let name = Self.preferredName(option.names, matching: partial.text) else {
                    return nil
                }
                return Suggestion(display: name,
                                  insertText: insertText(for: option, name: name),
                                  deleteCount: partial.typedLength,
                                  detail: option.specDescription,
                                  kind: .option,
                                  aliases: option.names.filter { $0 != name },
                                  priority: option.priority)
            }
            let known = Set(node.options.flatMap(\.names))
            let extra = overlaySuggestions(
                overlays?.overlay(for: walked)?.options ?? [], except: known,
                partial: partial, kind: .option)
            return finished(CompletionResult(
                suggestions: rank(options + extra, partial: partial.text, command: commandName)))
        }

        var suggestions: [Suggestion] = []
        if argIndex == 0 {
            /* Subcommands may carry aliases (`name: ["a", "add"]`); match the
               typed prefix against every alias and show the one that fits —
               the full word when nothing is typed, so lists read as
               "add", never "a". */
            suggestions += node.subcommands.filter { !$0.isHidden }.compactMap { sub in
                guard let name = Self.preferredName(sub.names, matching: partial.text) else {
                    return nil
                }
                return Suggestion(display: name,
                                  insertText: insertText(for: sub, name: name),
                                  deleteCount: partial.typedLength,
                                  detail: sub.specDescription,
                                  kind: .subcommand,
                                  aliases: sub.names.filter { $0 != name },
                                  priority: sub.priority)
            }
            /* Whatever `--help` lists at this level that the spec doesn't —
               a subcommand added since the corpus was published. The spec's
               own rows keep their descriptions and generators. */
            let known = Set(node.subcommands.flatMap(\.names))
            suggestions += overlaySuggestions(
                overlays?.overlay(for: walked)?.subcommands ?? [], except: known,
                partial: partial, kind: .subcommand)
        }
        let positional = node.args
        if argIndex < positional.count {
            let arg = positional[argIndex]
            let argResult = argSuggestions(for: arg, partial: partial, command: commandName)
            suggestions += argResult.suggestions
            let ranked = rank(suggestions, partial: partial.text, command: commandName)
            return finished(CompletionResult(suggestions: ranked, pendingArg: argResult.pendingArg))
        }
        return finished(CompletionResult(
            suggestions: rank(suggestions, partial: partial.text, command: commandName)))
    }

    /* The first word: the command itself. Offered once something is typed
       (an empty prompt stays quiet), and only for a plain name — a path, a
       flag or an assignment is the shell's business. Recency is recorded
       under the empty command key; picks made *inside* a command count too,
       so the commands actually used here rise above alphabetical order. */
    private func commandName(_ partial: Token, searchPath: String) -> CompletionResult {
        guard let commands, !partial.text.isEmpty, !partial.text.hasPrefix("-"),
              !partial.text.contains("/"), !partial.text.contains("=")
        else { return CompletionResult(suggestions: []) }
        let suggestions = commands.commands(matching: partial.text, searchPath: searchPath)
            .map { entry in
                Suggestion(display: entry.name, insertText: entry.name,
                           deleteCount: partial.typedLength, detail: entry.description,
                           kind: .command)
            }
        return CompletionResult(suggestions: rank(suggestions, partial: partial.text, command: ""))
    }

    /// Rows for overlay entries whose names the spec doesn't already have.
    private func overlaySuggestions(_ entries: [OverlayLevel.Entry], except known: Set<String>,
                                    partial: Token, kind: Suggestion.Kind) -> [Suggestion] {
        entries.compactMap { entry in
            guard !entry.names.contains(where: { known.contains($0) }),
                  let name = Self.preferredName(entry.names, matching: partial.text)
            else { return nil }
            return Suggestion(display: name, insertText: name, deleteCount: partial.typedLength,
                              detail: entry.description, kind: kind,
                              aliases: entry.names.filter { $0 != name })
        }
    }

    private func argSuggestions(for arg: SpecNode, partial: Token,
                                command: String) -> CompletionResult {
        var suggestions = arg.staticSuggestions.map { entry in
            Suggestion(display: entry.name,
                       insertText: entry.insertValue.map(Self.stripCursorMark) ?? entry.name,
                       deleteCount: partial.typedLength,
                       detail: entry.description,
                       kind: .argument)
        }
        suggestions = rank(suggestions, partial: partial.text, command: command)
        // Templates and generators need the session's cwd and a shell run —
        // the caller resolves them and merges.
        let pending = (arg.templates.isEmpty && arg.generators.isEmpty)
            ? nil : PendingArg(node: arg, partial: partial)
        return CompletionResult(suggestions: suggestions, pendingArg: pending)
    }

    /* Insertions end exactly where the word ends — no trailing space. The
       word is what was chosen; whether a space, an `=`, or Return comes
       next is the user's call (the controller keeps the popup down until
       the buffer moves on, so the completed word isn't offered again). */
    private func insertText(for node: SpecNode, name: String) -> String {
        if let insert = node.insertValue { return Self.stripCursorMark(insert) }
        return name
    }

    /// Which of a node's aliases to surface: with nothing typed, the longest
    /// (the canonical word); otherwise the first alias the partial matches
    /// (exact-case prefix, then case-insensitive prefix, then substring —
    /// the same ladder `rank` scores by). nil when no alias matches.
    static func preferredName(_ names: [String], matching partial: String) -> String? {
        guard !names.isEmpty else { return nil }
        let longest: ([String]) -> String? = { $0.max { $0.count < $1.count } }
        if partial.isEmpty { return longest(names) }
        // Within the best-matching tier, prefer the canonical (longest)
        // alias: "bun i" should read "install", not "i".
        // The whole-word tier folds into the prefix tier here: "bun i" should
        // still read "install", not "i".
        let matched = names.compactMap { name in
            FuzzyMatcher.match(partial, in: name).map { (name: name, tier: min($0.tier, 4)) }
        }
        guard let bestTier = matched.map(\.tier).max() else { return nil }
        return longest(matched.filter { $0.tier == bestTier }.map(\.name))
    }

    /// fig's insertValue may carry a `{cursor}` placeholder; v1 inserts the
    /// part before it (cursor repositioning needs another protocol verb).
    static func stripCursorMark(_ value: String) -> String {
        guard let range = value.range(of: "{cursor}") else { return value }
        return String(value[..<range.lowerBound])
    }

    private func rank(_ suggestions: [Suggestion], partial: String,
                      command: String) -> [Suggestion] {
        var scored: [Suggestion] = suggestions.compactMap { suggestion in
            guard let match = FuzzyMatcher.match(partial, in: suggestion.display) else { return nil }
            var s = suggestion
            s.score = match.rank
            s.matchedOffsets = match.offsets
            /* Typing an alias in full — "npm i" for install — is as strong a
               signal as typing the word itself: someone who knows the short
               form means that item, so it outranks "info" and "init", which
               merely start with the letter. The row still reads "install"
               and Return still inserts it. */
            if !partial.isEmpty, suggestion.aliases.contains(partial) {
                s.score = max(s.score, FuzzyMatcher.Match(tier: 5, score: 0, offsets: []).rank)
            }
            return s
        }
        let recent: (Suggestion) -> Double = { [recency] s in
            var last = recency?.lastUse(command: command, display: s.display)
            if command.isEmpty, let inside = recency?.lastUse(command: s.display) {
                last = max(last ?? .distantPast, inside)
            }
            return last?.timeIntervalSince1970 ?? -Double.infinity
        }
        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            let (r0, r1) = (recent($0), recent($1))
            if r0 != r1 { return r0 > r1 }  // picked before → first, newest first
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.display < $1.display
        }
        if scored.count > 50 { scored.removeLast(scored.count - 50) }
        return scored
    }
}
