import Foundation
import Testing
@testable import Sill

/* A generator-fed argument (cd) has nothing to show synchronously: while the
   generator answers for the new partial, the list built for the previous
   partial is carried — narrowed, and with each row's delete count moved by
   the typed characters — so a Return that lands before the answer replaces
   the word instead of appending to it ("cd mem" → "cd memmembers"). */

private func folder(_ name: String, deleteCount: Int) -> Suggestion {
    Suggestion(display: name + "/", insertText: name, deleteCount: deleteCount,
               detail: "", kind: .folder)
}

private let listedForEmptyPartial = [
    folder("members", deleteCount: 0),
    folder("media", deleteCount: 0),
    folder("src", deleteCount: 0),
    Suggestion(display: "../", insertText: "..", deleteCount: 0, detail: "", kind: .folder),
]

@Test func carriedListNarrowsAndMovesTheDeleteCount() {
    let carried = CompletionController.carried(
        listedForEmptyPartial,
        from: Token(text: "", typedLength: 0),
        to: Token(text: "mem", typedLength: 3))
    #expect(carried?.map(\.display) == ["members/"])
    #expect(carried?.first?.deleteCount == 3)
}

@Test func carriedListFollowsABackspace() {
    let shown = [folder("members", deleteCount: 3)]
    let carried = CompletionController.carried(
        shown, from: Token(text: "mem", typedLength: 3), to: Token(text: "me", typedLength: 2))
    #expect(carried?.first?.deleteCount == 2)
}

@Test func carriedListKeepsTheGeneratorsDeleteCountConvention() {
    // A custom generator replaces only the query term after the last "/":
    // rows for "src/" carry deleteCount 0 though the token is 4 long. The
    // carry moves that count by the keystroke, not to the token's length.
    let shown = [folder("components", deleteCount: 0)]
    let carried = CompletionController.carried(
        shown, from: Token(text: "src/", typedLength: 4), to: Token(text: "src/co", typedLength: 6))
    #expect(carried?.first?.deleteCount == 2)
}

@Test func carriedListRefusesAnotherDirectory() {
    let intoChild = CompletionController.carried(
        listedForEmptyPartial,
        from: Token(text: "sr", typedLength: 2), to: Token(text: "src/", typedLength: 4))
    #expect(intoChild == nil)
    let backToParent = CompletionController.carried(
        listedForEmptyPartial,
        from: Token(text: "src/", typedLength: 4), to: Token(text: "src", typedLength: 3))
    #expect(backToParent == nil)
}

@Test func carriedListIsEmptyWhenNothingMatches() {
    let carried = CompletionController.carried(
        listedForEmptyPartial,
        from: Token(text: "", typedLength: 0), to: Token(text: "zzz", typedLength: 3))
    #expect(carried?.isEmpty == true)
}
