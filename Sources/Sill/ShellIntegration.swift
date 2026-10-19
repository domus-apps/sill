import Foundation

/* Installs the zsh integration: a small block appended to ~/.zshrc — a
   blank separator, a comment saying what the line is, and one guarded
   `source` of ~/Library/Application Support/Sill/sill.zsh. That file is a
   link the app keeps pointed at the sill.zsh inside its bundle, so ~/.zshrc
   is written only on install and removal, never because the app moved.
   Removal takes the whole block back out, separator included, so the file
   reads as if Sill had never been there. The file is backed up once before
   Sill ever touches it. */
enum ShellIntegration {
    /// The comment line above the source line; also how installs are found.
    static let marker = "# Sill — terminal completions (managed by Sill.app; toggle in its Settings)"
    /// The pre-1.0 single-line form carried this trailing tag; still
    /// recognized so older installs are removed cleanly.
    private static let legacyMarker = "# Sill terminal completions"

    /// What the block sources. `$HOME` rather than the expanded path, so a
    /// ~/.zshrc shared between Macs through a dotfiles repo works on each.
    static let sourceLine =
        #"[[ -r "$HOME/Library/Application Support/Sill/sill.zsh" ]] && source "$HOME/Library/Application Support/Sill/sill.zsh""#

    static var zshrcURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
    }

    /// The link the block sources.
    static var linkURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sill/sill.zsh")
    }

    /// The bundled integration script; nil under `swift run` (no bundle).
    static var scriptURL: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("sill.zsh"),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    static var isInstalled: Bool {
        guard let contents = try? String(contentsOf: zshrcURL, encoding: .utf8) else {
            return false
        }
        return isInstalled(in: contents)
    }

    /// True when installation is possible at all (bundled app).
    static var isAvailable: Bool { scriptURL != nil }

    static func install() throws {
        guard let script = scriptURL else {
            throw NSError(domain: "Sill", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "The integration script is only available in the bundled app."])
        }
        // Turned on in this copy, so this copy's script is the one to load.
        try link(to: script.path)
        let contents = (try? String(contentsOf: zshrcURL, encoding: .utf8)) ?? ""
        if isInstalled(in: contents) {
            if let migrated = migrating(contents) { try writeZshrc(migrated) }
        } else {
            try writeZshrc(adding(block: sourceLine, to: contents))
        }
    }

    static func uninstall() throws {
        if let contents = try? String(contentsOf: zshrcURL, encoding: .utf8) {
            try writeZshrc(removingBlock(from: contents))
        }
        try? FileManager.default.removeItem(at: linkURL)
    }

    /* At launch: point the link at a script that exists, and move a block
       from before the link (one that sourced a bundle's sill.zsh by its
       full path) over to it. Those blocks broke whenever the copy of Sill
       that wrote them was deleted (Sill first run from the unzipped
       download, later kept only in /Applications): every shell skipped the
       guarded source while Settings still showed the switch on, and only
       turning it off and on again helped.

       Which copy the link names: the running one, unless another copy's
       script is linked (or, before the link, sourced) and still there while
       this copy lives outside an Applications folder, so that trying a build
       elsewhere doesn't take the user's shells along with it. */
    static func prepare() {
        guard let script = scriptURL, !script.path.contains("/AppTranslocation/"),
              let contents = try? String(contentsOf: zshrcURL, encoding: .utf8),
              isInstalled(in: contents)
        else { return }
        let fm = FileManager.default
        let linked = try? fm.destinationOfSymbolicLink(atPath: linkURL.path)
        let target = chosenScript(current: linked ?? bundleScripts(in: contents).first,
                                  ours: script.path, home: NSHomeDirectory(),
                                  exists: { fm.fileExists(atPath: $0) })
        do {
            if linked != target { try link(to: target) }
            // Never point the block at a link that isn't there.
            if fm.fileExists(atPath: linkURL.path), let migrated = migrating(contents) {
                try writeZshrc(migrated)
            }
        } catch {
            NSLog("Sill: could not prepare the shell integration: \(error)")
        }
    }

    /// Points the link at `script`, replacing whatever it named in one step.
    static func link(to script: String, at linkURL: URL = linkURL) throws {
        let fm = FileManager.default
        let directory = linkURL.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".sill.zsh.\(UUID().uuidString)")
        try fm.createSymbolicLink(atPath: temporary.path, withDestinationPath: script)
        guard rename(temporary.path, linkURL.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: temporary)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    /* Writes through a symlinked ~/.zshrc (a dotfiles repo) to its target,
       since an atomic write would replace the link itself, after backing up
       that target once: copying the link instead would only make a second
       link to the file about to change. */
    static func writeZshrc(_ contents: String, to zshrcURL: URL = zshrcURL) throws {
        let fm = FileManager.default
        let target = zshrcURL.resolvingSymlinksInPath()
        let backup = zshrcURL.appendingPathExtension("sill-backup")
        if fm.fileExists(atPath: target.path), !fm.fileExists(atPath: backup.path) {
            try? fm.copyItem(at: target, to: backup)
        }
        try contents.write(to: target, atomically: true, encoding: .utf8)
    }

    /// The script the link should name (see `prepare`).
    static func chosenScript(current: String?, ours: String, home: String,
                             exists: (String) -> Bool) -> String {
        let oursInApplications = ["/Applications/", home + "/Applications/"]
            .contains { ours.hasPrefix($0) }
        if let current, current != ours, exists(current), !oursInApplications { return current }
        return ours
    }

    // MARK: - Pure text edits (unit-tested)

    static func isInstalled(in contents: String) -> Bool {
        !sillLines(in: contents.components(separatedBy: "\n")).isEmpty
    }

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
        rewriting(contents, firstBlockAs: nil)
    }

    /// The file with a single block sourcing the link, where the first one
    /// was; nil when it already reads that way. Older blocks named a
    /// bundle's script, and the pre-1.0 form had no marker; a second block
    /// would source the script twice and is removed.
    static func migrating(_ contents: String) -> String? {
        let lines = contents.components(separatedBy: "\n")
        let ours = sillLines(in: lines).sorted()
        if ours.count == 2, ours[1] == ours[0] + 1,
           lines[ours[0]] == marker, lines[ours[1]] == sourceLine { return nil }
        return rewriting(contents, firstBlockAs: [marker, sourceLine])
    }

    /// Full paths of bundle scripts that blocks from before the link source.
    static func bundleScripts(in contents: String) -> [String] {
        let lines = contents.components(separatedBy: "\n")
        return sillLines(in: lines).sorted().compactMap { index in
            let line = lines[index]
            guard line != marker, !line.contains("$HOME"),
                  let match = line.firstMatch(of: #/"([^"]*/sill\.zsh)"/#)
            else { return nil }
            return String(match.1)
        }
    }

    /* The lines Sill wrote: each marker comment with the source line right
       under it, and the pre-1.0 single line carrying its trailing tag. A
       line the user wrote that sources some sill.zsh themselves, like a
       development checkout's, is theirs and left alone. */
    private static func sillLines(in lines: [String]) -> Set<Int> {
        var ours = Set<Int>()
        for (index, line) in lines.enumerated() {
            if line.contains(legacyMarker) {
                ours.insert(index)
            } else if line == marker {
                ours.insert(index)
                if index + 1 < lines.count, lines[index + 1].contains("source ") {
                    ours.insert(index + 1)
                }
            }
        }
        return ours
    }

    /// Takes Sill's lines out, putting `firstBlockAs` where the first of
    /// them was, and drops the blank separator above each block removed.
    private static func rewriting(_ contents: String, firstBlockAs replacement: [String]?) -> String {
        var lines = contents.components(separatedBy: "\n")
        // A trailing newline shows up as a final empty element; drop it here
        // and put it back at the end so blank-line bookkeeping stays exact.
        if lines.last == "" { lines.removeLast() }
        let ours = sillLines(in: lines)

        var kept: [String] = []
        var replaced = false
        var index = 0
        while index < lines.count {
            guard ours.contains(index) else {
                kept.append(lines[index])
                index += 1
                continue
            }
            var end = index
            while end < lines.count, ours.contains(end) { end += 1 }
            if let replacement, !replaced {
                kept += replacement
                replaced = true
            } else if end >= lines.count || lines[end].isEmpty, kept.last?.isEmpty == true {
                kept.removeLast()
            }
            index = end
        }
        // Never leave dangling blank lines at the end of the file.
        while kept.last?.isEmpty == true { kept.removeLast() }

        return kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
    }
}
