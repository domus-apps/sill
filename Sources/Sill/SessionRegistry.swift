import AppKit

/// One connected shell session and its latest reported state.
final class Session {
    let client: SocketServer.ClientID
    let sid: String
    let pid: Int32
    let tty: String
    /// $TERM_PROGRAM as the shell saw it ("Apple_Terminal" / "iTerm.app").
    let term: String
    /// Whether the terminal's background is dark (nil: unknown — follow
    /// the system appearance).
    let prefersDark: Bool?
    /// The shell's $PATH — where its commands actually come from.
    let searchPath: String

    var buffer = ""
    var cursor = 0
    var pwd = ""
    /// Terminal-grid cell (1-based) where the buffer starts — the plugin's
    /// once-per-prompt CPR anchor.
    var anchorRow = 1
    var anchorCol = 1
    var cols = 80
    var rows = 24
    /// Cell/text-area pixel sizes, from terminals the plugin queries itself.
    /// nil until the terminal has answered.
    var grid: GridInfo?
    /// The terminal never answered the plugin's geometry queries, so there
    /// is no grid coming and the window is the best anchor available.
    var noGrid = false

    init(client: SocketServer.ClientID, sid: String, pid: Int32, tty: String, term: String,
         prefersDark: Bool? = nil, searchPath: String? = nil) {
        self.client = client
        self.sid = sid
        self.pid = pid
        self.tty = tty
        self.term = term
        self.prefersDark = prefersDark
        self.searchPath = searchPath
            ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    }

    /// The caret's terminal-grid cell, derived from the anchor plus the
    /// cursor offset, folding line wraps. Clamped to the grid so a stale
    /// anchor can't put the popup off-screen.
    var caretCell: (row: Int, col: Int) {
        let index = (anchorCol - 1) + cursor
        // A wrapped line reaching the bottom scrolls the screen, effectively
        // moving the anchor up — clamping to the last row matches where the
        // caret visually ends up (a fresh anchor arrives next line-init).
        let row = min(anchorRow + index / max(cols, 1), rows)
        let col = index % max(cols, 1) + 1
        return (max(row, 1), max(col, 1))
    }
}

/// Terminals Sill knows how to position against: the frontmost app's bundle
/// id is matched to the $TERM_PROGRAM each session reported. VS Code's forks
/// (Insiders, VSCodium, Cursor) all report "vscode"; cmux embeds libghostty
/// and inherits Ghostty's environment.
enum SupportedTerminal {
    static let termPrograms: [String: [String]] = [
        "com.apple.Terminal": ["Apple_Terminal"],
        "com.googlecode.iterm2": ["iTerm.app"],
        "com.microsoft.VSCode": ["vscode"],
        "com.microsoft.VSCodeInsiders": ["vscode"],
        "com.vscodium": ["vscode"],
        "com.todesktop.230313mzl4w4u92": ["vscode"],  // Cursor
        "com.mitchellh.ghostty": ["ghostty"],
        "com.cmuxterm.app": ["ghostty", "cmux"],
    ]

    static func supports(bundleID: String, termProgram: String) -> Bool {
        termPrograms[bundleID]?.contains(termProgram) ?? false
    }

    /// Electron apps expose their web content to AX only once an assistive
    /// client asks — Sill has to ask before the caret can be located.
    static func isElectron(bundleID: String) -> Bool {
        termPrograms[bundleID] == ["vscode"]
    }

    /// Terminals whose accessibility tree has no caret: the popup is placed
    /// from the cell grid the plugin measures (see GridInfo) instead.
    static func usesGrid(bundleID: String) -> Bool {
        termPrograms[bundleID]?.contains("ghostty") ?? false
    }
}

/// All connected sessions. The activity model is intentionally simple:
/// keystrokes only ever come from the focused tab, so the session whose
/// buffer update arrived last IS the active one — provided a supported
/// terminal is frontmost and it is the app that session lives in.
final class SessionRegistry {
    private(set) var sessions: [SocketServer.ClientID: Session] = [:]
    private(set) var activeClient: SocketServer.ClientID?

    func register(_ session: Session) {
        sessions[session.client] = session
    }

    func remove(_ client: SocketServer.ClientID) {
        sessions.removeValue(forKey: client)
        if activeClient == client { activeClient = nil }
    }

    func markActive(_ client: SocketServer.ClientID) {
        activeClient = client
    }

    subscript(client: SocketServer.ClientID) -> Session? {
        sessions[client]
    }

    /// The session to complete for right now, or nil if the popup has no
    /// business being on screen.
    var activeSession: Session? {
        guard let client = activeClient, let session = sessions[client],
              let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              SupportedTerminal.supports(bundleID: bundleID, termProgram: session.term)
        else { return nil }
        return session
    }
}
