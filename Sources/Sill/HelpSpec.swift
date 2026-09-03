import Foundation

/* Turning a CLI's own `--help` output into a completion spec, for commands
   the corpus doesn't cover. Heuristic by design: the common generators
   (clap, cobra, commander, argparse, Go's flag, GNU getopt_long) all print
   "  -s, --long <ARG>   description" rows and, under a "Commands" heading,
   "  subcommand   description" rows — that covers most of what people
   type. What the parser can't read it leaves out: a missing option is
   cheap, a wrong one is confusing. */
struct DerivedSpec: Equatable {
    struct Option: Equatable {
        enum Argument: Equatable { case required, optional }

        var names: [String]
        var description: String
        /// nil: a plain flag. `.optional` for `--color[=WHEN]` forms — the
        /// parser must not swallow the next word for those.
        var argument: Argument?
        var argumentName: String?
    }

    struct Subcommand: Equatable {
        /// Canonical name first, aliases after ("install, i").
        var names: [String]
        var description: String
    }

    var description: String
    var options: [Option]
    var subcommands: [Subcommand]

    var isEmpty: Bool { options.isEmpty && subcommands.isEmpty }

    /// The Fig.Spec-shaped object the engine evaluates. Subcommands come
    /// out flagged `_sillUnexplored`: their own options are learned the
    /// first time the user reaches them (`cmd sub --help`).
    func figObject(name: String) -> [String: Any] {
        var object: [String: Any] = ["name": name]
        if !description.isEmpty { object["description"] = description }
        if !options.isEmpty {
            object["options"] = options.map { option -> [String: Any] in
                var entry: [String: Any] = ["name": option.names]
                if !option.description.isEmpty { entry["description"] = option.description }
                if let argument = option.argument {
                    var arg: [String: Any] = ["name": option.argumentName ?? "value"]
                    if argument == .optional { arg["isOptional"] = true }
                    entry["args"] = arg
                }
                return entry
            }
        }
        if !subcommands.isEmpty {
            object["subcommands"] = subcommands.map { sub -> [String: Any] in
                var entry: [String: Any] = ["name": sub.names, "_sillUnexplored": true]
                if !sub.description.isEmpty { entry["description"] = sub.description }
                return entry
            }
        }
        return object
    }
}

enum HelpParser {
    private enum Section { case unknown, options, commands, other }
    private enum Item { case none, option, subcommand }

    /// `command` lets example lines ("deno run main.ts") be told apart from
    /// wrapped descriptions.
    static func parse(_ raw: String, command: String? = nil) -> DerivedSpec {
        let lines = stripANSI(raw)
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\t", with: "    ") }

        var options: [DerivedSpec.Option] = []
        var subcommands: [DerivedSpec.Subcommand] = []
        var seenOptionNames: Set<String> = []
        var seenSubcommands: Set<String> = []
        var section = Section.unknown
        var last = Item.none
        var lastIndent = 0

        func appendContinuation(_ text: String) {
            switch last {
            case .option:
                guard let index = options.indices.last else { return }
                options[index].description = joinDescription(options[index].description, text)
            case .subcommand:
                guard let index = subcommands.indices.last else { return }
                subcommands[index].description = joinDescription(subcommands[index].description, text)
            case .none:
                break
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                last = .none
                continue
            }
            let indent = line.prefix(while: { $0 == " " }).count

            if let kind = sectionKind(ofHeader: trimmed, indent: indent) {
                // An indented group label inside a command list ("Execution:"
                // under deno's "Commands:") keeps the list going.
                if !(indent > 0 && section == .commands && kind == .other) {
                    section = kind
                }
                last = .none
                continue
            }
            // argparse lists subparsers as a positional "{add,remove}" whose
            // choices follow, indented one level deeper.
            if section != .commands, indent > 0, trimmed.hasPrefix("{"),
               trimmed.contains(","), trimmed.contains("}") {
                section = .commands
                last = .none
                continue
            }

            // A wrapped description of the previous row: indented past the
            // row itself and not a row of its own. Example lines ("deno run
            // main.ts", or bun's "lint   Run a package.json script" column)
            // are neither — they're dropped.
            let isRowStart = (trimmed.hasPrefix("-") && optionNames(in: trimmed) != nil)
                || (section == .commands && parseSubcommandRow(trimmed) != nil)
            if last != .none, indent > lastIndent + 1, !isRowStart {
                if !isExampleLine(trimmed, command: command) { appendContinuation(trimmed) }
                continue
            }

            if trimmed.hasPrefix("-"), section != .other {
                if let option = parseOptionRow(trimmed) {
                    let fresh = option.names.filter { !seenOptionNames.contains($0) }
                    if !fresh.isEmpty {
                        seenOptionNames.formUnion(fresh)
                        options.append(option)
                        last = .option
                        lastIndent = indent
                        continue
                    }
                }
                last = .none
                continue
            }

            if section == .commands, indent > 0,
               let sub = parseSubcommandRow(trimmed) ?? parseOverflowingSubcommandRow(trimmed),
               !seenSubcommands.contains(sub.names[0]) {
                seenSubcommands.insert(sub.names[0])
                subcommands.append(sub)
                last = .subcommand
                lastIndent = indent
                continue
            }

            last = .none
        }

        return DerivedSpec(description: leadingDescription(lines),
                           options: options, subcommands: subcommands)
    }

    private static func isExampleLine(_ trimmed: String, command: String?) -> Bool {
        if let command, trimmed == command || trimmed.hasPrefix(command + " ") { return true }
        // "lint                 Run a package.json script": a lone word, a
        // column gap, then text — an example column, not wrapped prose.
        if let gap = trimmed.firstRange(of: #/\s{2,}/#), !trimmed[..<gap.lowerBound].contains(" ") {
            return true
        }
        return false
    }

    // MARK: - Rows

    /// "Options:", "Available Commands:", "Global Flags:", "USAGE" — short
    /// titles at the margin. Options are recognized anywhere except in
    /// sections that are clearly something else (examples, arguments);
    /// subcommand rows only under headings that name commands, or under
    /// free-form group titles like pnpm's "Manage your dependencies:".
    private static func sectionKind(ofHeader trimmed: String, indent: Int) -> Section? {
        guard indent <= 2, let first = trimmed.first, first.isLetter else { return nil }
        var title = trimmed
        if title.hasSuffix(":") {
            title.removeLast()
        } else {
            // man-page style: an unindented ALL-CAPS word or two.
            guard indent == 0, title.count >= 4, title == title.uppercased(),
                  title.allSatisfy({ $0.isLetter || $0 == " " })
            else { return nil }
        }
        title = title.trimmingCharacters(in: .whitespaces)
        guard title.count <= 48, title.split(separator: " ").count <= 5,
              !title.contains(where: { ".,;<>[]()=".contains($0) })
        else { return nil }
        let lower = title.lowercased()
        // "Usage of server:" (Go's flag) heads the option rows themselves.
        if lower.hasPrefix("usage") { return .unknown }
        if lower.contains("command") { return .commands }
        if lower.contains("option") || lower.contains("flag") { return .options }
        let other = ["argument", "example", "environment", "variable", "see also", "learn more",
                     "exit", "alias", "note", "description", "synopsis", "author", "bug", "copyright"]
        if other.contains(where: { lower.contains($0) }) { return .other }
        // "Manage your dependencies:", "Tooling:", "Other:" — a titled group
        // of rows in a help screen is almost always a group of commands.
        return trimmed.hasSuffix(":") ? .commands : .other
    }

    private static let flagPattern = #/^(-{1,2}[A-Za-z0-9?#@][\w.+-]*)(.*)$/#
    /// A value placeholder after a flag: "<dir>", "[=WHEN]", "=FILE",
    /// "OUTPUT", "[HOST/]OWNER/REPO", "value" — one token, no prose.
    private static func isArgumentPlaceholder(_ rest: String) -> Bool {
        guard !rest.contains(" "), let first = rest.first else { return false }
        if "<[=".contains(first) || first.isUppercase { return true }
        return rest.wholeMatch(of: #/[a-z][\w-]*(?:\.\.\.)?/#) != nil
    }

    /// The flag names in a row's leading segment, or nil when the row
    /// doesn't start with a flag at all ("- a bullet").
    private static func optionNames(in trimmed: String) -> [String]? {
        parseOptionRow(trimmed)?.names
    }

    private static func parseOptionRow(_ trimmed: String) -> DerivedSpec.Option? {
        // The names live before the first run of two spaces; the
        // description after it (or on the next line, Go-flag style).
        var segment = trimmed
        var description = ""
        if let gap = trimmed.firstRange(of: #/\s{2,}/#) {
            segment = String(trimmed[..<gap.lowerBound])
            description = String(trimmed[gap.upperBound...])
        }

        var names: [String] = []
        var argument: DerivedSpec.Option.Argument?
        var argumentName: String?
        var trailingProse = ""
        for part in segment.split(separator: ",") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard let match = piece.wholeMatch(of: flagPattern) else { continue }
            let name = String(match.1)
            guard name != "-", name != "--" else { continue }
            names.append(name)
            let rest = match.2.trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { continue }
            if isArgumentPlaceholder(rest) {
                let optional = rest.hasPrefix("[") && rest.hasSuffix("]")
                if argument == nil || !optional { argument = optional ? .optional : .required }
                if argumentName == nil { argumentName = cleanArgumentName(rest) }
            } else {
                // "-v verbose output": a single-space description.
                trailingProse = rest
            }
        }
        guard !names.isEmpty else { return nil }
        if description.isEmpty { description = trailingProse }
        return DerivedSpec.Option(names: names, description: cleanDescription(description),
                                  argument: argument, argumentName: argumentName)
    }

    private static let subcommandPattern =
        #/^(?<name>[A-Za-z][\w:.+-]*)(?<aliases>(?:,\s*[A-Za-z][\w:.+-]*)*)(?:\s+(?:\[[^\]]*\]|<[^>]*>|\.\.\.))*(?:\s{2,}(?<desc>\S.*))?$/#

    private static func parseSubcommandRow(_ trimmed: String) -> DerivedSpec.Subcommand? {
        guard let match = trimmed.wholeMatch(of: subcommandPattern) else { return nil }
        let name = String(match.name)
        // ALL-CAPS words are placeholders ("COMMAND"), not commands.
        guard name != name.uppercased() || name.count == 1 else { return nil }
        var names = [name]
        for alias in match.aliases.split(separator: ",") {
            let piece = alias.trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty, !names.contains(piece) { names.append(piece) }
        }
        return DerivedSpec.Subcommand(names: names,
                                      description: cleanDescription(String(match.desc ?? "")))
    }

    /// "approve-scripts Approve npm lifecycle scripts": a name too long for
    /// its column, one space, then a capitalized description. Only tried
    /// where a row is expected — wrapped prose is caught earlier as a
    /// continuation.
    private static func parseOverflowingSubcommandRow(_ trimmed: String) -> DerivedSpec.Subcommand? {
        guard let match = trimmed.wholeMatch(of: #/^([a-z][\w:+-]*) ([A-Z][^.]*\.?)$/#) else {
            return nil
        }
        return DerivedSpec.Subcommand(names: [String(match.1)],
                                      description: cleanDescription(String(match.2)))
    }

    // MARK: - Text

    /// The command's own one-liner: the first paragraph at the margin that
    /// isn't the usage line or a heading (clap, cobra and argparse all put
    /// it there).
    private static func leadingDescription(_ lines: [String]) -> String {
        var block: [String] = []
        for line in lines.prefix(40) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if block.isEmpty { continue } else { break }
            }
            let indent = line.prefix(while: { $0 == " " }).count
            let skip = indent > 0 || trimmed.lowercased().hasPrefix("usage")
                || sectionKind(ofHeader: trimmed, indent: indent) != nil
            if skip {
                if block.isEmpty { continue } else { break }
            }
            block.append(trimmed)
        }
        var text = block.joined(separator: " ")
        if text.count > 100, let sentence = text.range(of: ". ") {
            text = String(text[..<sentence.lowerBound])
        }
        if text.count > 140 { text = String(text.prefix(139)) + "…" }
        return text
    }

    private static func cleanDescription(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespaces)
        // "run   ./my-script.ts     Execute a file": drop an example column
        // that precedes the real description.
        if let gap = cleaned.firstRange(of: #/\s{2,}/#),
           !cleaned[..<gap.lowerBound].contains(" ") {
            cleaned = String(cleaned[gap.upperBound...])
        }
        cleaned = cleaned.replacing(#/\s+/#, with: " ").trimmingCharacters(in: .whitespaces)
        if cleaned.count > 200 { cleaned = String(cleaned.prefix(199)) + "…" }
        return cleaned
    }

    private static func joinDescription(_ existing: String, _ more: String) -> String {
        guard existing.count < 200 else { return existing }
        let joined = existing.isEmpty ? more : existing + " " + more
        return cleanDescription(joined)
    }

    private static func cleanArgumentName(_ rest: String) -> String? {
        let stripped = rest.trimmingCharacters(in: CharacterSet(charactersIn: "<>[]=. "))
        guard let first = stripped.split(whereSeparator: { "|,".contains($0) }).first else {
            return nil
        }
        let name = first.trimmingCharacters(in: CharacterSet(charactersIn: "<>[]=. ")).lowercased()
        return name.isEmpty ? nil : name
    }

    /// Colors, cursor movement, OSC sequences and man-style overstrike.
    static func stripANSI(_ text: String) -> String {
        var out = text.replacing(#/\x1B\[[0-9;?]*[ -\/]*[@-~]/#, with: "")
        out = out.replacing(#/\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)/#, with: "")
        out = out.replacing(#/.\x08/#, with: "")
        return out
    }
}
