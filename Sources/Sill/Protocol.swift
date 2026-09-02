import Foundation

/* The wire protocol between sill.zsh and the app: newline-delimited JSON,
   one persistent connection per shell session. The zsh side hand-writes its
   JSON (see ShellIntegration/sill.zsh), so decoding must tolerate garbage —
   a malformed line is dropped, never fatal. */

enum ShellMessage: Equatable {
    /// `dark` is the terminal's own background (from the plugin's OSC 11
    /// query), nil when the terminal didn't answer.
    case hello(sid: String, pid: Int32, tty: String, term: String, dark: Bool?)
    /// The edit buffer as of this keystroke. `row`/`col` anchor the START of
    /// the buffer (the cell where the prompt ends, from the plugin's CPR
    /// query); the caret cell is derived from `cur` and `cols`.
    case buffer(sid: String, buf: String, cur: Int, pwd: String,
                row: Int, col: Int, cols: Int, rows: Int)
    /// A steering key the plugin consumed while the popup was up ("tab",
    /// "up", "down", "ret", "esc"). ZLE receives keys regardless of Secure
    /// Keyboard Entry — the shell is the legitimate recipient — which is
    /// why steering lives here and not in an event tap.
    case key(sid: String, key: String)
    case end(sid: String)

    var sid: String {
        switch self {
        case .hello(let sid, _, _, _, _), .buffer(let sid, _, _, _, _, _, _, _),
             .key(let sid, _), .end(let sid):
            return sid
        }
    }

    static func decode(_ line: Data) -> ShellMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let dict = object as? [String: Any],
              let type = dict["t"] as? String,
              let sid = dict["sid"] as? String
        else { return nil }
        switch type {
        case "hello":
            guard let pid = dict["pid"] as? Int else { return nil }
            return .hello(sid: sid, pid: Int32(pid),
                          tty: dict["tty"] as? String ?? "",
                          term: dict["term"] as? String ?? "",
                          dark: dict["dark"] as? Bool)
        case "buf":
            guard let buf = dict["buf"] as? String,
                  let cur = dict["cur"] as? Int,
                  let pwd = dict["pwd"] as? String
            else { return nil }
            return .buffer(sid: sid, buf: buf, cur: cur, pwd: pwd,
                           row: dict["row"] as? Int ?? 1,
                           col: dict["col"] as? Int ?? 1,
                           cols: dict["cols"] as? Int ?? 80,
                           rows: dict["rows"] as? Int ?? 24)
        case "key":
            guard let key = dict["key"] as? String else { return nil }
            return .key(sid: sid, key: key)
        case "end":
            return .end(sid: sid)
        default:
            return nil
        }
    }
}

/// App → shell: whether the popup is on screen (the plugin binds/unbinds
/// the steering keys on this) and whether the user has arrow-navigated
/// (gates Return-to-insert, which the plugin must decide synchronously).
struct PopupStateCommand {
    var visible: Bool
    var navigated: Bool

    func encoded() -> Data {
        Data(#"{"t":"popup","visible":\#(visible),"nav":\#(navigated)}"#.utf8 + [0x0A])
    }
}

/// App → shell: replace the last `del` characters before the caret with
/// `text`. The plugin's reply parser expects exactly this field order.
struct InsertCommand {
    var del: Int
    var text: String

    func encoded() -> Data {
        var line = #"{"t":"insert","del":\#(del),"text":""#
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": line += "\\\\"
            case "\"": line += "\\\""
            case "\n": line += "\\n"
            case "\t": line += "\\t"
            case "\r": line += "\\r"
            default: line.unicodeScalars.append(scalar)
            }
        }
        line += "\"}\n"
        return Data(line.utf8)
    }
}

/// Splits a byte stream into newline-terminated frames, buffering partials.
struct LineFramer {
    private var pending = Data()

    mutating func consume(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(pending.subdata(in: pending.startIndex..<newline))
            pending.removeSubrange(pending.startIndex...newline)
        }
        // A line that never terminates is an attack or a bug — cap it.
        if pending.count > 1 << 20 { pending.removeAll() }
        return lines
    }
}
