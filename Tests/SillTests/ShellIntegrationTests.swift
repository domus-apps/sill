import Foundation
import Testing
@testable import Sill

private let src = #"[[ -r "/Applications/Sill.app/Contents/Resources/sill.zsh" ]] && source "/Applications/Sill.app/Contents/Resources/sill.zsh""#
private let block = ShellIntegration.marker + "\n" + src + "\n"

@Test func installAppendsABlockSeparatedByOneBlankLine() {
    #expect(ShellIntegration.adding(block: src, to: "alias ll='ls -l'\n")
        == "alias ll='ls -l'\n\n" + block)
    // No trailing newline on the existing file: still exactly one blank line.
    #expect(ShellIntegration.adding(block: src, to: "alias ll='ls -l'")
        == "alias ll='ls -l'\n\n" + block)
    // Already ends with a blank line: don't add a second one.
    #expect(ShellIntegration.adding(block: src, to: "alias ll='ls -l'\n\n")
        == "alias ll='ls -l'\n\n" + block)
    // Empty (or missing) rc file: no leading blank line.
    #expect(ShellIntegration.adding(block: src, to: "") == block)
}

@Test func uninstallLeavesNoTrace() {
    let installed = ShellIntegration.adding(block: src, to: "alias ll='ls -l'\n")
    #expect(ShellIntegration.removingBlock(from: installed) == "alias ll='ls -l'\n")
}

@Test func uninstallCollapsesToOneBlankWhenUserAddedMoreBelow() {
    let contents = "alias ll='ls -l'\n\n" + block + "\nexport FOO=1\n"
    #expect(ShellIntegration.removingBlock(from: contents) == "alias ll='ls -l'\n\nexport FOO=1\n")
}

@Test func uninstallKeepsTheSeparatorWhenItWouldGlueLines() {
    let contents = "alias ll='ls -l'\n\n" + block + "export FOO=1\n"
    #expect(ShellIntegration.removingBlock(from: contents) == "alias ll='ls -l'\n\nexport FOO=1\n")
}

@Test func uninstallRemovesTheLegacySingleLineForm() {
    let legacy = "alias ll='ls -l'\n" + src + "  # Sill terminal completions\n"
    #expect(ShellIntegration.removingBlock(from: legacy) == "alias ll='ls -l'\n")
}

@Test func uninstallOfAnRcThatWasOnlySillYieldsAnEmptyFile() {
    #expect(ShellIntegration.removingBlock(from: block) == "")
}

@Test func uninstallLeavesUnrelatedFilesUntouched() {
    #expect(ShellIntegration.removingBlock(from: "x\n") == "x\n")  // untouched when absent
}

private let current = ShellIntegration.marker + "\n" + ShellIntegration.sourceLine + "\n"

@Test func anOldBlockMovesToTheLinkWhereItWas() {
    let before = "alias ll='ls -l'\n\n" + block + "export FOO=1\n"
    #expect(ShellIntegration.migrating(before) == "alias ll='ls -l'\n\n" + current + "export FOO=1\n")
    // The pre-1.0 single line gains the marker comment.
    #expect(ShellIntegration.migrating("alias ll='ls -l'\n" + src + "  # Sill terminal completions\n")
        == "alias ll='ls -l'\n" + current)
    // Already current, trailing blank lines and all: nothing to write.
    #expect(ShellIntegration.migrating("alias ll='ls -l'\n\n" + current + "\n\n") == nil)
}

@Test func aSecondBlockIsRemovedSoTheScriptLoadsOnce() {
    let twice = "alias ll='ls -l'\n\n" + block + "\nexport FOO=1\n\n" + current
    #expect(ShellIntegration.migrating(twice) == "alias ll='ls -l'\n\n" + current + "\nexport FOO=1\n")
}

@Test func aSillLineTheUserWroteIsTheirs() {
    let own = "source \"$HOME/Dev/sill/ShellIntegration/sill.zsh\"\n"
    #expect(!ShellIntegration.isInstalled(in: own))
    #expect(ShellIntegration.removingBlock(from: own + "\n" + current) == own)
    #expect(ShellIntegration.migrating(own + "\n" + block) == own + "\n" + current)
    #expect(ShellIntegration.bundleScripts(in: own + "\n" + block)
        == ["/Applications/Sill.app/Contents/Resources/sill.zsh"])
    #expect(ShellIntegration.bundleScripts(in: current).isEmpty)
}

@Test func theLinkFollowsTheAppOnlyWhenItShould() {
    let applications = "/Applications/Sill.app/Contents/Resources/sill.zsh"
    let download = "/Users/me/Downloads/Sill.app/Contents/Resources/sill.zsh"
    let build = "/Users/me/Dev/sill/build/Sill.app/Contents/Resources/sill.zsh"
    func chosen(_ current: String?, _ ours: String, _ existing: Set<String>) -> String {
        ShellIntegration.chosenScript(current: current, ours: ours, home: "/Users/me",
                                      exists: existing.contains)
    }
    // Nothing linked, or the copy it named was deleted: whichever app runs.
    #expect(chosen(nil, build, [build]) == build)
    #expect(chosen(download, applications, [applications]) == applications)
    #expect(chosen(applications, build, [build]) == build)
    // Another copy is still there: only one in an Applications folder takes over.
    #expect(chosen(download, applications, [applications, download]) == applications)
    #expect(chosen(download, "/Users/me/Applications/Sill.app/Contents/Resources/sill.zsh",
                   [download]) == "/Users/me/Applications/Sill.app/Contents/Resources/sill.zsh")
    #expect(chosen(applications, build, [applications, build]) == applications)
}

@Test func aSymlinkedZshrcIsBackedUpAndEditedThroughTheLink() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("sill-rc-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let dotfiles = root.appendingPathComponent("dotfiles/zshrc")
    try fm.createDirectory(at: dotfiles.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "alias ll='ls -l'\n".write(to: dotfiles, atomically: true, encoding: .utf8)
    let rc = root.appendingPathComponent(".zshrc")
    try fm.createSymbolicLink(at: rc, withDestinationURL: dotfiles)

    try ShellIntegration.writeZshrc("edited\n", to: rc)
    #expect(try fm.destinationOfSymbolicLink(atPath: rc.path) == dotfiles.path)   // still a link
    #expect(try String(contentsOf: dotfiles, encoding: .utf8) == "edited\n")
    let backup = root.appendingPathComponent(".zshrc.sill-backup")
    #expect((try? fm.destinationOfSymbolicLink(atPath: backup.path)) == nil)      // a real file
    #expect(try String(contentsOf: backup, encoding: .utf8) == "alias ll='ls -l'\n")
    // Only once: a later edit keeps the original.
    try ShellIntegration.writeZshrc("edited again\n", to: rc)
    #expect(try String(contentsOf: backup, encoding: .utf8) == "alias ll='ls -l'\n")
}

@Test func theLinkIsReplacedInPlace() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("sill-link-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let link = root.appendingPathComponent("Sill/sill.zsh")
    try ShellIntegration.link(to: "/Applications/Sill.app/Contents/Resources/sill.zsh", at: link)
    #expect(try fm.destinationOfSymbolicLink(atPath: link.path)
        == "/Applications/Sill.app/Contents/Resources/sill.zsh")
    try ShellIntegration.link(to: "/Users/me/Applications/Sill.app/Contents/Resources/sill.zsh", at: link)
    #expect(try fm.destinationOfSymbolicLink(atPath: link.path)
        == "/Users/me/Applications/Sill.app/Contents/Resources/sill.zsh")
    #expect(try fm.contentsOfDirectory(atPath: link.deletingLastPathComponent().path) == ["sill.zsh"])
}
