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

    init(sessions: SessionRegistry, server: SocketServer, specDirectories: [URL],
         derived: DerivedSpecStore) {
        self.sessions = sessions
        self.server = server
        self.derived = derived
        engine = SpecEngine(specDirectories: specDirectories, derived: derived)
        commandCatalog = CommandCatalog(specDirectories: specDirectories, derived: derived)
        parser = CompletionParser(engine: engine, recency: recency)

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
        }
        let command = result.commandTokens.first ?? ""
        presentedCommand = command
        var suggestions = result.suggestions
        var awaitingGenerators = false

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
                    let ordered = self.recency.sorted(generated, command: command)
                    self.present(suggestions + ordered, for: session)
                }
            }
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

    private func present(_ suggestions: [Suggestion], for session: Session) {
        /* The word is finished: one suggestion left and it is exactly what
           has been typed. There is nothing to complete, so stay out of the
           way — Return runs the command and Tab goes to the shell, instead
           of both being held for a completion that would change nothing. */
        if suggestions.count == 1,
           suggestions[0].insertsNothing(before: String(session.buffer.prefix(session.cursor))) {
            hide()
            return
        }
        guard !suggestions.isEmpty, sessions.activeSession === session,
              let placement = CaretLocator.locate(for: session)
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
        popup.show(suggestions, at: placement)
        popupClient = session.client
        shownPlacement = placement
        startPlacementWatchdog()
        sendPopupState()
    }

    private func hide() {
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
                  let now = CaretLocator.locate(for: session), now.precise == shown.precise,
                  abs(now.rect.minY - shown.rect.minY) < 2,      // same line
                  abs(now.rect.minX - shown.rect.minX) < 240     // not a window move
            else {
                hide()
                return
            }
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
        server.send(
            PopupStateCommand(visible: popup.isVisible, navigated: popup.userNavigated),
            to: client)
    }

    // MARK: - Keys (from the shell's ZLE widgets)

    func keyPressed(_ key: String, from client: SocketServer.ClientID) {
        guard popup.isVisible, client == popupClient,
              let session = sessions[client]
        else { return }
        switch key {
        case "up":
            popup.moveSelection(by: -1)
            sendPopupState()  // navigated → Return may insert now
        case "down":
            popup.moveSelection(by: 1)
            sendPopupState()
        case "tab":
            if let suggestion = popup.selectedSuggestion {
                acceptInto(session, suggestion)
            }
        case "ret":
            // Return inserts the highlighted item whenever the popup is up —
            // one predictable rule (Esc first if the command should run).
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
        /* Insertions carry no trailing space, so the buffer the shell reports
           back still ends in the completed word — which would match itself
           and re-open the popup on the very item just chosen. Stay down
           until the buffer changes again (a space, `/`, more typing);
           a folder insertion ends in "/" and should keep listing, so it is
           exempt. */
        if !suggestion.insertText.hasSuffix("/") {
            let prefix = String(session.buffer.prefix(session.cursor))
            let suffix = String(session.buffer.dropFirst(session.cursor))
            suppressedBuffer = String(prefix.dropLast(suggestion.deleteCount))
                + suggestion.insertText + suffix
        }
        server.send(InsertCommand(del: suggestion.deleteCount, text: suggestion.insertText),
                    to: session.client)
        // The choice is made: down now, not when the shell echoes the buffer
        // back (which re-runs the pipeline — for a folder, the next listing).
        hide()
    }
}
