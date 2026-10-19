import Foundation
import Testing
@testable import Sill

/* A generator like fig's filepaths(): its trigger asks for a fresh run only
   when the token's directory changes, so within a line the last listing is
   reused. Each run here answers with a new name, the way a folder listing
   changes after `git clone`. */
private let listingSpec = """
{ name: "cd", args: { generators: {
    trigger: function() { return false; },
    custom: function() { globalThis.runs = (globalThis.runs || 0) + 1;
                         return Promise.resolve([{ name: "run" + globalThis.runs + "/", type: "folder" }]); }
} } }
"""

@MainActor
private func listing(_ runner: GeneratorRunner, _ arg: SpecNode) async -> [String] {
    let partial = Tokenizer.tokenize("cd ").last!
    return await withCheckedContinuation { continuation in
        runner.run(arg: arg, tokens: ["cd", ""], partial: partial, cwd: "/tmp", sid: "s1") {
            continuation.resume(returning: $0.map(\.display))
        }
    }
}

@MainActor
@Test func folderListingsLastOneLine() async throws {
    let engine = SpecEngine()
    let arg = try #require(engine.evaluateJSON(listingSpec)?.args.first)
    let runner = GeneratorRunner()
    #expect(await listing(runner, arg) == ["run1/"])
    #expect(await listing(runner, arg) == ["run1/"])   // same line: reused
    runner.forget(sid: "s1")                          // the line ended
    #expect(await listing(runner, arg) == ["run2/"])
}

/* A run that is still going when its line ends: its listing reaches the
   caller but not the cache, or the next line would be served it. */
private let slowSpec = """
{ name: "cd", args: { generators: {
    trigger: function() { return false; },
    custom: function() { globalThis.runs = (globalThis.runs || 0) + 1;
                         return new Promise(function(resolve) { globalThis.finishRun = resolve; }); }
} } }
"""

@MainActor
@Test func aListingThatArrivesAfterTheLineEndedIsNotKept() async throws {
    let engine = SpecEngine()
    let arg = try #require(engine.evaluateJSON(slowSpec)?.args.first)
    let runner = GeneratorRunner()
    let partial = Tokenizer.tokenize("cd ").last!
    var delivered: [String]?
    runner.run(arg: arg, tokens: ["cd", ""], partial: partial, cwd: "/tmp", sid: "s1") {
        delivered = $0.map(\.display)
    }
    runner.forget(sid: "s1")   // Return before the listing came back
    let finish = try #require(arg.value.context.objectForKeyedSubscript("finishRun"))
    finish.call(withArguments: [[["name": "old/", "type": "folder"]]])
    await Task.yield()
    while delivered == nil { await Task.yield() }
    #expect(delivered == ["old/"])
    // The next line runs the generator again instead of reusing "old/".
    runner.run(arg: arg, tokens: ["cd", ""], partial: partial, cwd: "/tmp", sid: "s1") { _ in }
    #expect(arg.value.context.objectForKeyedSubscript("runs").toInt32() == 2)
}
