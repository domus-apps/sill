import Foundation
import Testing
@testable import Sill

/// A Homebrew prefix in a temp folder: a formula installed by name (mole,
/// two commands), one pulled in as a dependency (gettext), a cask with a
/// binary, and a file put in bin by hand.
private struct FakePrefix {
    let root: URL
    var bin: String { root.appendingPathComponent("bin").path }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sill-brew-\(UUID().uuidString)")
        try formula("mole", "1.56.1", commands: ["mo", "mole"], onRequest: true,
                    desc: #"Deep clean and optimize your Mac"#)
        try formula("gettext", "0.26", commands: ["msgfmt"], onRequest: false,
                    desc: "GNU internationalization (i18n) and localization (l10n) library")
        try cask("tool", "2.0", command: "toolctl", desc: "Controls the tool")
        try executable(at: bin + "/handmade")
    }

    func formula(_ name: String, _ version: String, commands: [String], onRequest: Bool,
                 desc: String) throws {
        let keg = root.appendingPathComponent("Cellar/\(name)/\(version)")
        let receipt: [String: Any] = ["installed_on_request": onRequest, "homebrew_version": "5.0.0"]
        try write(JSONSerialization.data(withJSONObject: receipt), to: keg.appendingPathComponent("INSTALL_RECEIPT.json"))
        let ruby = "class Formula < Formula\n  desc \"\(desc)\"\n  homepage \"https://example.com\"\nend\n"
        try write(Data(ruby.utf8), to: keg.appendingPathComponent(".brew/\(name).rb"))
        for command in commands {
            try executable(at: keg.appendingPathComponent("bin/\(command)").path)
            try link(bin + "/" + command, to: "../Cellar/\(name)/\(version)/bin/\(command)")
        }
    }

    func cask(_ token: String, _ version: String, command: String, desc: String) throws {
        let room = root.appendingPathComponent("Caskroom/\(token)")
        try executable(at: room.appendingPathComponent("\(version)/\(command)").path)
        let older = room.appendingPathComponent(".metadata/1.0/20250101000000.000/Casks/\(token).json")
        try write(JSONSerialization.data(withJSONObject: ["desc": "Old description"]), to: older)
        let newer = room.appendingPathComponent(".metadata/\(version)/20260901000000.000/Casks/\(token).json")
        try write(JSONSerialization.data(withJSONObject: ["token": token, "desc": desc]), to: newer)
        try link(bin + "/" + command, to: room.appendingPathComponent("\(version)/\(command)").path)
    }

    func executable(at path: String) throws {
        try write(Data("#!/bin/sh\n".utf8), to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    private func link(_ path: String, to destination: String) throws {
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: destination)
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test func homebrewCommandsInstalledOnPurposeAreOffered() throws {
    let brew = try FakePrefix()
    defer { brew.remove() }
    let scan = CommandCatalog.scan(brew.bin)
    #expect(scan.names == ["mo", "mole", "msgfmt", "toolctl", "handmade"])
    #expect(scan.installed == [
        "mo": "Deep clean and optimize your Mac",
        "mole": "Deep clean and optimize your Mac",
        "toolctl": "Controls the tool",   // the newest install's caskfile
        "handmade": "",
    ])   // msgfmt came along as a dependency
    #expect(Homebrew.prefix(ofBin: brew.bin) != nil)
    #expect(Homebrew.prefix(ofBin: "/bin") == nil)
}

@Test func catalogOffersHomebrewCommandsWithoutDefinitions() throws {
    let brew = try FakePrefix()
    defer { brew.remove() }
    let specs = FileManager.default.temporaryDirectory
        .appendingPathComponent("sill-brew-specs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: specs, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: specs) }
    // mole has a definition with no one-liner; msgfmt has one but stays a
    // PATH command like any other.
    let index: [String: Any] = [
        "version": "t", "files": ["mole.js", "msgfmt.js"],
        "descriptions": ["msgfmt": "Compile message catalogs"],
    ]
    try JSONSerialization.data(withJSONObject: index).write(to: specs.appendingPathComponent("index.json"))
    let catalog = CommandCatalog(specDirectories: [specs], derived: nil)

    let mo = catalog.commands(matching: "mo", searchPath: brew.bin)
        .sorted { $0.name < $1.name }
    #expect(mo.map(\.name) == ["mo", "mole"])
    #expect(mo.allSatisfy { $0.description == "Deep clean and optimize your Mac" })
    #expect(catalog.commands(matching: "msg", searchPath: brew.bin).map(\.description)
            == ["Compile message catalogs"])

    // A command installed while Sill runs shows up on the next keystroke.
    #expect(catalog.commands(matching: "rg", searchPath: brew.bin).isEmpty)
    try brew.formula("ripgrep", "15.1.0", commands: ["rg"], onRequest: true,
                     desc: #"Search tool like grep and The Silver Searcher"#)
    #expect(catalog.commands(matching: "rg", searchPath: brew.bin).map(\.name) == ["rg"])

    // Only the command that actually runs counts: an earlier folder on PATH
    // with its own `mo` hides Homebrew's.
    let earlier = brew.root.appendingPathComponent("earlier").path
    try brew.executable(at: earlier + "/mo")
    #expect(catalog.commands(matching: "mo", searchPath: earlier + ":" + brew.bin)
                .map(\.name) == ["mole"])
}

@Test func rubyDescriptionLine() {
    #expect(Homebrew.desc(inRuby: "cask \"x\" do\n  name \"X\"\n  desc \"Say \\\"hi\\\"\"\nend") == #"Say "hi""#)
    #expect(Homebrew.desc(inRuby: "class X < Formula\n  homepage \"h\"\nend") == nil)
}
