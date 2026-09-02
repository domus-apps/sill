import Foundation
import Testing
@testable import Sill

@Test func framerSplitsAndBuffersPartials() {
    var framer = LineFramer()
    #expect(framer.consume(Data("{\"a\":1}\n{\"b\"".utf8)).count == 1)
    let rest = framer.consume(Data(":2}\n".utf8))
    #expect(rest.count == 1)
    #expect(String(data: rest[0], encoding: .utf8) == "{\"b\":2}")
}

@Test func framerDropsARunawayLine() {
    var framer = LineFramer()
    #expect(framer.consume(Data(repeating: 0x41, count: 2 << 20)).isEmpty)
    // The oversized partial was discarded; a fresh line still parses.
    let lines = framer.consume(Data("x\n".utf8))
    #expect(String(data: lines[0], encoding: .utf8) == "x")
}

@Test func decodesTheThreeMessageTypes() {
    let hello = ShellMessage.decode(Data(
        #"{"t":"hello","v":1,"sid":"1-2","pid":42,"tty":"/dev/ttys004","term":"iTerm.app"}"#.utf8))
    #expect(hello == .hello(sid: "1-2", pid: 42, tty: "/dev/ttys004", term: "iTerm.app", dark: nil))

    let darkHello = ShellMessage.decode(Data(
        #"{"t":"hello","v":1,"sid":"1-2","pid":42,"tty":"/dev/ttys004","term":"Apple_Terminal","dark":true}"#.utf8))
    #expect(darkHello == .hello(sid: "1-2", pid: 42, tty: "/dev/ttys004", term: "Apple_Terminal", dark: true))

    let buf = ShellMessage.decode(Data(
        #"{"t":"buf","sid":"1-2","buf":"git ch","cur":6,"pwd":"/x","row":3,"col":5,"cols":80,"rows":24}"#.utf8))
    #expect(buf == .buffer(sid: "1-2", buf: "git ch", cur: 6, pwd: "/x",
                           row: 3, col: 5, cols: 80, rows: 24))

    #expect(ShellMessage.decode(Data(#"{"t":"end","sid":"1-2"}"#.utf8)) == .end(sid: "1-2"))
}

@Test func malformedLinesAreDroppedNotFatal() {
    #expect(ShellMessage.decode(Data("not json".utf8)) == nil)
    #expect(ShellMessage.decode(Data(#"{"t":"buf","sid":"x"}"#.utf8)) == nil)   // missing fields
    #expect(ShellMessage.decode(Data(#"{"t":"unknown","sid":"x"}"#.utf8)) == nil)
    #expect(ShellMessage.decode(Data(#"{"sid":"x"}"#.utf8)) == nil)
}

@Test func insertCommandEscapesLikeTheZshParserExpects() {
    let plain = InsertCommand(del: 2, text: "checkout ").encoded()
    #expect(String(data: plain, encoding: .utf8) ==
        #"{"t":"insert","del":2,"text":"checkout "}"# + "\n")

    let tricky = InsertCommand(del: 0, text: "a\"b\\c\nd\te").encoded()
    #expect(String(data: tricky, encoding: .utf8) ==
        #"{"t":"insert","del":0,"text":"a\"b\\c\nd\te"}"# + "\n")
}

@Test func caretCellFoldsWrapsAndScrolling() {
    let session = Session(client: 1, sid: "s", pid: 1, tty: "", term: "Apple_Terminal")
    session.cols = 10
    session.rows = 24
    session.anchorRow = 5
    session.anchorCol = 3

    session.cursor = 0
    #expect(session.caretCell == (5, 3))

    session.cursor = 7   // still on the anchor row
    #expect(session.caretCell == (5, 10))

    session.cursor = 8   // wrapped to the next row's first cell
    #expect(session.caretCell == (6, 1))

    session.anchorRow = 24
    session.cursor = 25  // wraps past the bottom → clamped to the last row
    #expect(session.caretCell.row == 24)
}
