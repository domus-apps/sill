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
