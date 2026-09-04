import AppKit

/* The conductor: buffer updates come in from the sessions, suggestions go
   out to the popup, steering keys come in from the shell (ZLE widgets the
   plugin binds while the popup is up — the shell receives keys regardless
   of Secure Keyboard Entry, so no event tap is involved), and accepted
   completions go back as insert commands. Main thread only. */
final class CompletionController {
    private let sessions: SessionRegistry
    private let server: SocketServer
    private let engine: SpecEngine
    private let derived: DerivedSpecStore
    private let commandCatalog: CommandCatalog
    private var parser: CompletionParser
    private let generators = GeneratorRunner()
    private let recency = RecencyStore()
    private let popup = PopupPanel()
    /// Command of the list on screen — the key recency is recorded under.
    private var presentedCommand = ""
    /// The client currently shown the popup — popup-state messages go here,
    /// including the final "hidden" after the session itself went away.
    private var popupClient: SocketServer.ClientID?

    /// Escape dismissed the popup; stay hidden until the buffer changes.
    private var suppressedBuffer: String?
    /// Where the popup was placed, and a watchdog that re-checks the caret
    /// while it's up: a terminal window that closed, moved, resized, scrolled
    /// or switched tabs no longer has its caret where it was — hide rather
    /// than linger over nothing (the socket only reports the shell's exit,
    /// which some close paths deliver late or not at all).
    private var shownPlacement: CaretLocator.Placement?
    private var placementWatchdog: Timer?
    /// Drops generator replies that arrive after the buffer moved on.
    private var generation = 0
    /// Puts the loading row up once a generator has run for 150ms — long
    /// enough that a spinner informs rather than flickers.
    private var loadingTimer: DispatchWorkItem?

    init(sessions: SessionRegistry, server: SocketServer, specDirectories: [URL],
         derived: DerivedSpecStore) {
        self.sessions = sessions
        self.server = server
        self.derived = derived
        engine = SpecEngine(specDirectories: specDirectories, derived: derived)
        commandCatalog = CommandCatalog(specDirectories: specDirectories, derived: derived)
        parser = CompletionParser(engine: engine, recency: recency, overlays: derived)

        // A spec learned from --help just landed: the list for the buffer
        // on screen may be different now.
        NotificationCenter.default.addObserver(
            forName: DerivedSpecStore.updated, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let session = self.sessions.activeSession else { return }
            self.bufferChanged(session)
        }

        popup.onChoose = { [weak self] suggestion in
            self?.accept(suggestion)
        }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(hideFromNotification),
                              name: NSWorkspace.didActivateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(hideFromNotification),
                              name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    // MARK: - Session events

    func bufferChanged(_ session: Session) {
        if let suppressed = suppressedBuffer {
            if session.buffer == suppressed {
                hide()  // Esc, or a just-completed word echoing back
                return
            }
            suppressedBuffer = nil
        }
        refresh(session)
    }

    func lineEnded(_ session: Session) {
        xtermLineOrigin[session.sid] = nil   // the next prompt may be elsewhere
        xtermSettledRead[session.sid] = nil
        hide()
    }

    func sessionClosed(_ client: SocketServer.ClientID) {
        if sessions.activeClient == client || popupClient == client { hide() }
    }

    @objc private func hideFromNotification() {
        // Frontmost app or Space changed — even switching terminal windows
        // warrants a hide; the next keystroke re-shows in the right place.
        if sessions.activeSession == nil { hide() }
    }

    // MARK: - Completion pipeline

    private func refresh(_ session: Session) {
        guard sessions.activeSession === session else {
            hide()
            return
        }
        generation += 1
        let currentGeneration = generation
        cursorDeltaForGeneration = session.cursor - (lastReportedCursor[session.sid] ?? session.cursor)
        lastReportedCursor[session.sid] = session.cursor
        lastReportAt = CFAbsoluteTimeGetCurrent()

        // First-word completion is a preference; honour it as of this keystroke.
        parser.commands = AppPreferences.completesCommandNames ? commandCatalog : nil
        let result = parser.complete(buffer: session.buffer, cursor: session.cursor,
                                     searchPath: session.searchPath)
        if AppPreferences.learnsFromHelp {
            if let unknown = result.unknownCommand {
                derived.ensure(command: unknown, searchPath: session.searchPath)
            }
            if let path = result.unexploredPath {
                derived.explore(path: path, searchPath: session.searchPath)
            }
            if !result.path.isEmpty {
                // A command with a spec: read --help at this level once, for
                // whatever the spec is missing here.
                derived.augment(path: result.path, searchPath: session.searchPath)
            }
        }
        let command = result.commandTokens.first ?? ""
        presentedCommand = command
        var suggestions = result.suggestions
        var awaitingGenerators = false
        loadingTimer?.cancel()
        loadingTimer = nil

        if let pending = result.pendingArg {
            suggestions += TemplateResolver.suggestions(
                templates: pending.node.templates, partial: pending.partial, cwd: session.pwd)

            if !pending.node.generators.isEmpty {
                awaitingGenerators = true
                generators.run(arg: pending.node, tokens: result.commandTokens,
                               partial: pending.partial, cwd: session.pwd,
                               sid: session.sid) { [weak self] generated in
                    guard let self, self.generation == currentGeneration else { return }
                    // Already filtered by the runner (query-term aware). An
                    // empty result with nothing static to show is the moment
                    // to hide — not before, while the shell command runs.
                    self.loadingTimer?.cancel()
                    self.loadingTimer = nil
                    var ordered = self.recency.sorted(generated, command: command)
                    if ordered.contains(where: { $0.kind == .folder || $0.kind == .file }) {
                        // A generator that lists paths (cd's, for one) gets
                        // the same "../" entry as the native templates.
                        ordered = TemplateResolver.withParentEntry(ordered, partial: pending.partial)
                    }
                    self.present(suggestions + ordered, for: session)
                }
            }
        }
        if awaitingGenerators {
            let timer = DispatchWorkItem { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                if self.popup.isVisible {
                    self.popup.setLoading(true)
                } else {
                    self.present(suggestions, for: session, loading: true)
                }
            }
            loadingTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: timer)
        } else {
            popup.setLoading(false)
        }
        if suggestions.isEmpty, awaitingGenerators, popup.isVisible {
            // Keep the previous list on screen until the generator answers;
            // hiding here and re-showing 50ms later reads as a flicker on
            // every keystroke of a path argument.
            return
        }
        present(suggestions, for: session)
    }

    private var presented: [Suggestion] = []

    private func currentSuggestions() -> [Suggestion] { presented }

    /* xterm.js (VS Code) reports the caret where the terminal has DRAWN it,
       and the shell tells Sill about a keystroke before it even writes the
       echo the terminal will draw. So at the moment the buffer arrives the
       caret read is exactly one edit behind — the popup would open at the
       previous cell and hop over when the watchdog looks again. Waiting does
       not help reliably (Chromium updates its accessibility tree on its own
       schedule), but the edit itself is known: the cursor moved from where
       it was at the previous report to where it is now, and the caret
       element is one cell wide. Shift the read by that many cells. The cell
       width is refined from two settled reads on one row, since the element's
       width is rounded. Native terminals answer with the caret in place and
       are left alone. */
    private var cursorDeltaForGeneration = 0
    private var lastReportedCursor: [String: Int] = [:]
    private var lastReportAt = CFAbsoluteTime(0)
    private var xtermCellWidth: [String: CGFloat] = [:]
    private var xtermSettledRead: [String: (x: CGFloat, y: CGFloat, cursor: Int)] = [:]
    /* Where cursor 0 of the line being edited sits on its row. Once known,
       every keystroke on that row is placed by arithmetic alone — the read
       is a keystroke or more behind while typing runs ahead of the drawing,
       and following it would make the popup shake. Learned from the first
       shifted read, corrected by settled ones, forgotten with the line. */
    private var xtermLineOrigin: [String: (x0: CGFloat, y: CGFloat)] = [:]
    /// Reads this long after the last keystroke show the caret as drawn.
    private static let xtermSettleTime: CFAbsoluteTime = 0.2
    /// One placement per buffer state: a generator answering later must not
    /// re-read a caret that has since been drawn and shift it a second time.
    private var placementGeneration = -1
    private var placementForGeneration: CaretLocator.Placement?

    private func locateForPresent(_ session: Session) -> CaretLocator.Placement? {
        if placementGeneration == generation { return placementForGeneration }
        var placement = CaretLocator.locate(for: session)
        if session.term == "vscode", var found = placement, found.precise {
            let cell = xtermCellWidth[session.sid] ?? found.rect.width
            if let origin = xtermLineOrigin[session.sid], abs(origin.y - found.rect.minY) < 1 {
                found.rect.origin.x = origin.x0 + CGFloat(session.cursor) * cell
            } else {
                found.rect.origin.x += CGFloat(cursorDeltaForGeneration) * cell
                xtermLineOrigin[session.sid] = (found.rect.minX - CGFloat(session.cursor) * cell,
                                                found.rect.minY)
            }
            placement = found
        }
        placementGeneration = generation
        placementForGeneration = placement
        return placement
    }

    /// A read taken while nothing was being typed is the drawn caret: use
    /// two of them on one row to learn the real cell width.
    private func noteSettledRead(_ placement: CaretLocator.Placement, for session: Session) {
        guard session.term == "vscode", placement.precise else { return }
        let x = placement.rect.minX, y = placement.rect.minY
        if let previous = xtermSettledRead[session.sid], abs(previous.y - y) < 1,
           previous.cursor != session.cursor {
            let width = (x - previous.x) / CGFloat(session.cursor - previous.cursor)
            if width > 3, width < 30 { xtermCellWidth[session.sid] = width }
        }
        xtermSettledRead[session.sid] = (x, y, session.cursor)
        let cell = xtermCellWidth[session.sid] ?? placement.rect.width
        xtermLineOrigin[session.sid] = (x - CGFloat(session.cursor) * cell, y)
    }

    private func present(_ suggestions: [Suggestion], for session: Session, loading: Bool = false) {
        /* The word is finished: one suggestion left and it is exactly what
           has been typed. There is nothing to complete, so stay out of the
           way — Return runs the command and Tab goes to the shell, instead
           of both being held for a completion that would change nothing. */
        if !loading, suggestions.count == 1,
           suggestions[0].insertsNothing(before: String(session.buffer.prefix(session.cursor))) {
            hide()
            return
        }
        guard !suggestions.isEmpty || loading, sessions.activeSession === session,
              let placement = locateForPresent(session)
        else {
            hide()
            return
        }
        presented = suggestions
        if ProcessInfo.processInfo.environment["SILL_DEBUG_PLACEMENT"] != nil {
            NSLog("Sill placement: %@ precise=%d app=%@", NSStringFromRect(placement.rect),
                  placement.precise ? 1 : 0,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")
        }
        popup.setPrefersDark(session.prefersDark)
        popup.show(suggestions, at: placement, loading: loading)
        popupClient = session.client
        shownPlacement = placement
        startPlacementWatchdog()
        sendPopupState()
    }

    private func hide() {
        loadingTimer?.cancel()
        loadingTimer = nil
        presented = []
        placementWatchdog?.invalidate()
        placementWatchdog = nil
        shownPlacement = nil
        let wasVisible = popup.isVisible
        popup.hide()
        if wasVisible { sendPopupState() }
        popupClient = nil
    }

    private func startPlacementWatchdog() {
        guard placementWatchdog == nil else { return }
        placementWatchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self] _ in
            guard let self, popup.isVisible, let shown = shownPlacement else { return }
            guard let session = sessions.activeSession,
                  let now = CaretLocator.locate(for: session)
            else {
                hide()
                return
            }
            // While typing runs ahead of VS Code's drawing, its reads trail
            // the placement by design; judge them only once they have caught up.
            if session.term == "vscode",
               CFAbsoluteTimeGetCurrent() - lastReportAt < Self.xtermSettleTime { return }
            guard now.precise == shown.precise,
                  abs(now.rect.minY - shown.rect.minY) < 2,      // same line
                  abs(now.rect.minX - shown.rect.minX) < 240     // not a window move
            else {
                hide()
                return
            }
            noteSettledRead(now, for: session)
            // The caret drifted a few cells on the same line — the terminal
            // repainted after we placed the popup, or the user moved the
            // cursor. Follow it instead of blinking.
            if abs(now.rect.minX - shown.rect.minX) >= 1 {
                shownPlacement = now
                popup.move(to: now)
            }
        }
    }

    /// Tells the shell whether to hold the steering keys, and whether
    /// Return should insert (only after arrow navigation) — the plugin has
    /// to decide that synchronously on the keypress.
    private func sendPopupState() {
        guard let client = popupClient else { return }
        let exact = popup.isVisible && sessions[client].map { session in
            popup.selectedSuggestion?.insertsNothing(
                before: String(session.buffer.prefix(session.cursor))) ?? false
        } ?? false
        server.send(
            PopupStateCommand(visible: popup.isVisible, navigated: popup.userNavigated, exact: exact),
            to: client)
    }

    // MARK: - Keys (from the shell's ZLE widgets)

    /* An arrow tapped at the end of the list wraps round; an arrow HELD
       there stops, or the selection would race round the list until the key
       is let go. The shell reports key presses, not repeats, so the two are
       told apart by pace: repeats arrive at the system's key-repeat interval,
       taps a good deal slower. */
    private var lastArrow: (key: String, at: CFAbsoluteTime)?

    static func arrowWraps(sinceLast interval: CFAbsoluteTime?, repeatInterval: TimeInterval) -> Bool {
        guard let interval else { return true }
        return interval > repeatInterval * 2
    }

    private func arrow(_ key: String, delta: Int) {
        let now = CFAbsoluteTimeGetCurrent()
        let since = lastArrow.flatMap { $0.key == key ? now - $0.at : nil }
        lastArrow = (key, now)
        popup.moveSelection(by: delta, wrapping: Self.arrowWraps(
            sinceLast: since, repeatInterval: NSEvent.keyRepeatInterval))
        sendPopupState()  // navigated → Return may insert now
    }

    func keyPressed(_ key: String, from client: SocketServer.ClientID) {
        guard popup.isVisible, client == popupClient,
              let session = sessions[client]
        else { return }
        switch key {
        case "up":
            arrow(key, delta: -1)
        case "down":
            arrow(key, delta: 1)
        case "tab":
            if let suggestion = popup.selectedSuggestion {
                acceptInto(session, suggestion)
            }
        case "ret":
            /* Return inserts the highlighted item. (When that item is exactly
               what has been typed — "ls" with ls and lsof listed — the plugin
               runs the line itself, from the `exact` flag in the popup
               state, and this key never arrives.) */
            if let suggestion = popup.selectedSuggestion {
                acceptInto(session, suggestion)
            }
        case "esc":
            suppressedBuffer = session.buffer
            hide()
        default:
            break
        }
    }

    private func accept(_ suggestion: Suggestion) {
        guard let session = sessions.activeSession else { return }
        acceptInto(session, suggestion)
    }

    private func acceptInto(_ session: Session, _ suggestion: Suggestion) {
        recency.record(command: presentedCommand, display: suggestion.display)
        /* Insertions carry no trailing space or slash, so the buffer the
           shell reports back still ends in the completed word — which would
           match itself and re-open the popup on the very item just chosen.
           Stay down until the buffer changes again (a space, a "/", more
           typing). */
        let prefix = String(session.buffer.prefix(session.cursor))
        let suffix = String(session.buffer.dropFirst(session.cursor))
        suppressedBuffer = String(prefix.dropLast(suggestion.deleteCount))
            + suggestion.insertText + suffix
        server.send(InsertCommand(del: suggestion.deleteCount, text: suggestion.insertText),
                    to: session.client)
        // The choice is made: down now, not when the shell echoes the buffer
        // back (which re-runs the pipeline — for a folder, the next listing).
        hide()
    }
}
