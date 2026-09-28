import Foundation

/// Resolves only literal command aliases. Never evaluates shell code; the
/// original buffer and the partial token's deletion length stay untouched.
enum AliasExpansion {
    static func shell(_ input: [Token], aliases: [String: String]) -> [Token]? {
        var tokens = input
        var index = 0
        while index < tokens.count - 1, tokens[index].text.contains("=") { index += 1 }
        var seen: Set<String> = []
        while index < tokens.count - 1, !tokens[index].isQuoted,
              let value = aliases[tokens[index].text] {
            let name = tokens[index].text
            guard seen.insert(name).inserted, seen.count <= 20,
                  let replacement = words(value), !replacement.isEmpty else { return nil }
            tokens.replaceSubrange(index...index, with: replacement)
            // zsh permits aliases such as git='git --no-pager'.
            if tokens[index].text == name { break }
        }
        return tokens
    }

    static func git(_ input: [Token], aliases: [String: String],
                    builtins: Set<String>) -> [Token]? {
        var tokens = input
        var seen: Set<String> = []
        while let index = gitSubcommand(in: tokens), index < tokens.count - 1,
              !builtins.contains(tokens[index].text), let value = aliases[tokens[index].text] {
            guard seen.insert(tokens[index].text).inserted, seen.count <= 20,
                  !value.hasPrefix("!"), let replacement = words(value),
                  !replacement.isEmpty else { return nil }
            tokens.replaceSubrange(index...index, with: replacement)
        }
        return tokens
    }

    /// Find the Git subcommand, skipping global flags and their values.
    static func gitSubcommand(in tokens: [Token]) -> Int? {
        guard tokens.first.map({ ($0.text as NSString).lastPathComponent }) == "git" else { return nil }
        let takesValue: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env"]
        var index = 1
        while index < tokens.count {
            let word = tokens[index].text
            if word == "--" { return index + 1 < tokens.count ? index + 1 : nil }
            if takesValue.contains(word) { index += 2 }
            else if word.hasPrefix("-"), !word.isEmpty { index += 1 }
            else { return index }
        }
        return nil
    }

    /// Quotes and escaped literal characters are fine; expansion, redirection,
    /// pipelines, globbing, and compound commands need a real shell parser.
    static func words(_ value: String) -> [Token]? {
        var quote: Character?
        var escaped = false
        for character in value {
            if escaped { escaped = false; continue }
            if character == "\\", quote != "'" { escaped = true; continue }
            if let current = quote {
                if character == current { quote = nil }
                else if current == "\"", "$`".contains(character) { return nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if "\n\r;|&<>(){}$`*?[]~#".contains(character) {
                return nil
            }
        }
        guard quote == nil, !escaped else { return nil }
        var tokens = Tokenizer.tokenize(value)
        if tokens.last?.typedLength == 0 { tokens.removeLast() }
        return tokens
    }
}
