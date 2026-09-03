import Foundation
import Testing
@testable import Sill

/* The Korean table is checked against the source: every `L("…")` key in
   Sources/Sill has a translation, every translation keeps the same format
   specifiers, and the file parses. English needs no table — the key is the
   English text. */

private let sourcesURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/Sill")

private func keysInSource() throws -> Set<String> {
    let files = try FileManager.default.contentsOfDirectory(at: sourcesURL, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" }
    let pattern = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)""#)
    var keys: Set<String> = []
    for file in files {
        let text = try String(contentsOf: file, encoding: .utf8)
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let literal = String(text[Range(match.range(at: 1), in: text)!])
            // The literal is Swift source; the strings file uses the same escapes.
            keys.insert(literal)
        }
    }
    return keys
}

private func koreanTable() throws -> [String: String] {
    let url = sourcesURL.appendingPathComponent("Resources/ko.lproj/Localizable.strings")
    let data = try Data(contentsOf: url)
    var format = PropertyListSerialization.PropertyListFormat.openStep
    let object = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
    return try #require(object as? [String: String])
}

@Test func everySourceStringHasAKoreanTranslation() throws {
    let keys = try keysInSource()
    let table = try koreanTable()
    #expect(!keys.isEmpty)
    // The strings-file parser unescapes \n; compare on the unescaped form.
    let unescaped = Set(keys.map { $0.replacingOccurrences(of: "\\n", with: "\n") })
    let missing = unescaped.subtracting(table.keys)
    #expect(missing.isEmpty, "untranslated: \(missing)")
    let stale = Set(table.keys).subtracting(unescaped)
    #expect(stale.isEmpty, "no longer in source: \(stale)")
}

@Test func translationsKeepTheirFormatSpecifiers() throws {
    let specifier = try NSRegularExpression(pattern: "%[@d]")
    for (key, value) in try koreanTable() {
        #expect(!value.trimmingCharacters(in: .whitespaces).isEmpty, "empty: \(key)")
        let count: (String) -> Int = { specifier.numberOfMatches(in: $0, range: NSRange($0.startIndex..., in: $0)) }
        #expect(count(key) == count(value), "specifier mismatch: \(key)")
    }
}

@Test func lookupFallsBackToTheKey() {
    // Whatever the test host's language, an unknown key comes back verbatim.
    #expect(L("A string that is not in any table") == "A string that is not in any table")
    #expect(L("Corpus %@", "1.2") .contains("1.2"))
}
