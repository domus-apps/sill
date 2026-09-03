import Foundation

/* Installs the zsh integration: a small block appended to ~/.zshrc — a
   blank separator, a comment saying what the line is, and one guarded
   `source` of the sill.zsh inside the app bundle (stable across updates).
   Removal takes the whole block back out, separator included, so the file
   reads as if Sill had never been there. The file is backed up once before
   Sill ever touches it. */
enum ShellIntegration {
    /// The comment line above the source line; also how installs are found.
    static let marker = "# Sill — terminal completions (managed by Sill.app; toggle in its Settings)"
    /// The pre-1.0 single-line form carried this trailing tag; still
    /// recognized so older installs are removed cleanly.
    private static let legacyMarker = "# Sill terminal completions"

    static var zshrcURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
    }

    /// The bundled integration script; nil under `swift run` (no bundle).
    static var scriptURL: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("sill.zsh"),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    static var sourceLine: String? {
        guard let script = scriptURL else { return nil }
        return "[[ -r \"\(script.path)\" ]] && source \"\(script.path)\""
    }

    static var isInstalled: Bool {
        guard let contents = try? String(contentsOf: zshrcURL, encoding: .utf8) else {
            return false
        }
        return contents.components(separatedBy: "\n").contains(where: isOurs)
    }

    /// Lines Sill wrote: the marker comment, the source line (either form).
    private static func isOurs(_ line: String) -> Bool {
        line == marker || line.contains(legacyMarker)
            || (line.contains("source ") && line.contains("/sill.zsh\""))
    }

    /// True when installation is possible at all (bundled app).
    static var isAvailable: Bool { scriptURL != nil }

    static func install() throws {
        guard let line = sourceLine else {
            throw NSError(domain: "Sill", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "The integration script is only available in the bundled app."])
        }
        guard !isInstalled else { return }
        let fm = FileManager.default
        let contents = (try? String(contentsOf: zshrcURL, encoding: .utf8)) ?? ""

        // One-time backup before the first modification.
        let backup = zshrcURL.appendingPathExtension("sill-backup")
        if fm.fileExists(atPath: zshrcURL.path), !fm.fileExists(atPath: backup.path) {
            try? fm.copyItem(at: zshrcURL, to: backup)
        }

        try adding(block: line, to: contents).write(to: zshrcURL, atomically: true, encoding: .utf8)
    }

    static func uninstall() throws {
        guard let contents = try? String(contentsOf: zshrcURL, encoding: .utf8) else { return }
        try removingBlock(from: contents).write(to: zshrcURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Pure text edits (unit-tested)

    /// Appends the block: exactly one blank line of separation, the marker
    /// comment, then the source line.
    static func adding(block sourceLine: String, to contents: String) -> String {
        var contents = contents
        if !contents.isEmpty, !contents.hasSuffix("\n") { contents += "\n" }
        if !contents.isEmpty, !contents.hasSuffix("\n\n") { contents += "\n" }
        return contents + marker + "\n" + sourceLine + "\n"
    }

    /// Removes every line Sill wrote plus the blank separator above the
    /// block, so the file reads as if Sill had never been there. The
    /// separator is kept only when removing it would glue two unrelated
    /// lines together (the user appended something right after the block).
    static func removingBlock(from contents: String) -> String {
        var lines = contents.components(separatedBy: "\n")
        // A trailing newline shows up as a final empty element; drop it here
        // and put it back at the end so blank-line bookkeeping stays exact.
        if lines.last == "" { lines.removeLast() }

        while let index = lines.firstIndex(where: isOurs) {
            lines.remove(at: index)
            let above = index - 1
            if above >= 0, lines[above].isEmpty {
                let belowIsBlankOrEnd = index >= lines.count || lines[index].isEmpty
                if belowIsBlankOrEnd { lines.remove(at: above) }
            }
        }
        // Never leave dangling blank lines at the end of the file.
        while lines.last?.isEmpty == true { lines.removeLast() }

        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }
}
