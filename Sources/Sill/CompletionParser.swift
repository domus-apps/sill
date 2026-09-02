import Foundation

/// One completion the popup can offer.
struct Suggestion: Equatable {
    enum Kind {
        case subcommand, option, argument, file, folder
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
    /// Match quality, for ranking: 3 exact-case prefix, 2 prefix, 1 substring.
    var score: Int = 0
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
}

/* Walks a buffer prefix against a Fig spec tree and produces ranked
   suggestions. Pure logic apart from the JSValue-backed SpecNode reads —
   unit-testable with a small inline spec. */
struct CompletionParser {
    let engine: any SpecProviding
    /// Picks the user made before, per command — orders equal matches.
    var recency: RecencyStore? = nil

    func complete(buffer: String, cursor: Int) -> CompletionResult {
        let prefix = String(buffer.prefix(cursor))
        var tokens = Tokenizer.tokenize(prefix)

        // Complete only the rightmost simple command of a pipeline/list.
        if let lastSeparator = tokens.lastIndex(where: { $0.isSeparator }) {
            tokens = Array(tokens[(lastSeparator + 1)...])
        }
        // Leading environment assignments and wrappers change nothing about
        // the command's own completions.
        let wrappers: Set<String> = ["sudo", "env", "command", "builtin", "nohup", "time", "exec"]
        while let first = tokens.first, tokens.count > 1,
              first.text.contains("=") || wrappers.contains(first.text) {
            tokens.removeFirst()
        }

        guard tokens.count >= 2 else { return CompletionResult(suggestions: []) }
        let commandName = (tokens[0].text as NSString).lastPathComponent
        guard let root = engine.spec(for: commandName) else {
            return CompletionResult(suggestions: [])
        }

        let commandTokens = tokens.map(\.text)
        let partial = tokens.removeLast()
        var node = root
        var argsOnly = false
        var argIndex = 0
        var pendingOptionArg: SpecNode?

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
            var result = argSuggestions(for: pending, partial: partial, command: commandName)
            result.commandTokens = commandTokens
            return result
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
            return CompletionResult(suggestions: rank(options, partial: partial.text,
                                                      command: commandName),
                                    commandTokens: commandTokens)
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
        }
        let positional = node.args
        if argIndex < positional.count {
            let arg = positional[argIndex]
            let argResult = argSuggestions(for: arg, partial: partial, command: commandName)
            suggestions += argResult.suggestions
            let ranked = rank(suggestions, partial: partial.text, command: commandName)
            return CompletionResult(suggestions: ranked, pendingArg: argResult.pendingArg,
                                    commandTokens: commandTokens)
        }
        return CompletionResult(suggestions: rank(suggestions, partial: partial.text,
                                                  command: commandName),
                                commandTokens: commandTokens)
    }

    private func argSuggestions(for arg: SpecNode, partial: Token,
                                command: String) -> CompletionResult {
        var suggestions = arg.staticSuggestions.map { entry in
            Suggestion(display: entry.name,
                       insertText: (entry.insertValue.map(Self.stripCursorMark) ?? entry.name) + " ",
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

    private func insertText(for node: SpecNode, name: String) -> String {
        if let insert = node.insertValue { return Self.stripCursorMark(insert) }
        // A trailing space moves straight to the next word — except when the
        // option expects `=`-joined values often enough that fig marks it
        // via requiresSeparator (rare; skipped in v1).
        return name + " "
    }

    /// Which of a node's aliases to surface: with nothing typed, the longest
    /// (the canonical word); otherwise the first alias the partial matches
    /// (exact-case prefix, then case-insensitive prefix, then substring —
    /// the same ladder `rank` scores by). nil when no alias matches.
    static func preferredName(_ names: [String], matching partial: String) -> String? {
        guard !names.isEmpty else { return nil }
        let longest: ([String]) -> String? = { $0.max { $0.count < $1.count } }
        if partial.isEmpty { return longest(names) }
        let lower = partial.lowercased()
        // Within the best-matching tier, prefer the canonical (longest)
        // alias: "bun i" should read "install", not "i".
        for tier in [names.filter { $0.hasPrefix(partial) },
                     names.filter { $0.lowercased().hasPrefix(lower) },
                     names.filter { $0.lowercased().contains(lower) }]
        where !tier.isEmpty {
            return longest(tier)
        }
        return nil
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
            var s = suggestion
            if partial.isEmpty {
                s.score = 2
            } else if s.display.hasPrefix(partial) {
                s.score = 3
            } else if s.display.lowercased().hasPrefix(partial.lowercased()) {
                s.score = 2
            } else if s.display.lowercased().contains(partial.lowercased()) {
                s.score = 1
            } else {
                return nil
            }
            return s
        }
        let recent: (Suggestion) -> Double = { [recency] s in
            recency?.lastUse(command: command, display: s.display)?.timeIntervalSince1970
                ?? -Double.infinity
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
