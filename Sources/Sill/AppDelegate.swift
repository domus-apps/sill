import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let updater = UpdaterController()
    private let server = SocketServer()
    private let sessions = SessionRegistry()
    private let specStore = SpecStore()
    private var completions: CompletionController?
    private var settingsWindow: SettingsWindowController?
    private var onboardingWindow: OnboardingWindowController?

    /// Where completion specs live, most specific first: an explicit dev
    /// override, the downloaded corpus, then anything bundled in the app.
    static var specDirectories: [URL] {
        var directories: [URL] = []
        if let override = ProcessInfo.processInfo.environment["SILL_SPEC_DIR"] {
            directories.append(URL(fileURLWithPath: override))
        }
        directories.append(SpecStore.specsDirectory)
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("specs") {
            directories.append(bundled)
        }
        return directories
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if TranslocationHealer.healIfNeeded() { return }
        completions = CompletionController(
            sessions: sessions, server: server, specDirectories: Self.specDirectories)
        setUpMainMenu()
        setUpStatusItem()
        startServer()
        specStore.startPeriodicUpdates()

        NotificationCenter.default.addObserver(
            forName: AppPreferences.changed, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateStatusItemVisibility()
        }

        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--onboarding") || !OnboardingWindowController.isCompleted {
            showOnboarding()
        }
        if arguments.contains("--settings") {
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }

    /* Reopening (Dock icon while Settings is open, `open -a Sill` again)
       surfaces Settings — the app has no other principal window. */
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        if OnboardingWindowController.isCompleted {
            showSettings()
        } else {
            showOnboarding()
        }
        return false
    }

    // MARK: - Shell sessions

    private func startServer() {
        server.onMessage = { [weak self] client, message in
            self?.handle(message, from: client)
        }
        server.onDisconnect = { [weak self] client in
            if ProcessInfo.processInfo.environment["SILL_DEBUG_AUTOINSERT"] != nil {
                NSLog("Sill: session closed (client %d)", client)
            }
            self?.completions?.sessionClosed(client)
            self?.sessions.remove(client)
        }
        do {
            try server.start()
        } catch {
            NSLog("Sill: could not open the shell socket: \(error)")
        }
    }

    private func handle(_ message: ShellMessage, from client: SocketServer.ClientID) {
        switch message {
        case .hello(let sid, let pid, let tty, let term, let dark):
            sessions.register(Session(client: client, sid: sid, pid: pid, tty: tty, term: term,
                                      prefersDark: dark))
            if ProcessInfo.processInfo.environment["SILL_DEBUG_AUTOINSERT"] != nil {
                NSLog("Sill: hello term=%@ dark=%@", term, dark.map { "\($0)" } ?? "unknown")
            }
        case .buffer(_, let buf, let cur, let pwd, _, _, let cols, let rows):
            guard let session = sessions[client] else { return }
            session.buffer = buf
            session.cursor = cur
            session.pwd = pwd
            session.cols = cols
            session.rows = rows
            sessions.markActive(client)
            /* Round-trip smoke test for the shell integration (`zle -F` reply
               handler, key widgets, _sill_apply), used by scripted
               verification only: "git ch" fakes a popup so the plugin binds
               its keys; the forwarded Tab (see .key below) then inserts. */
            if ProcessInfo.processInfo.environment["SILL_DEBUG_AUTOINSERT"] != nil {
                NSLog("Sill: buf=%@ cur=%d active=%@",
                      buf, cur, sessions.activeSession != nil ? "yes" : "no")
                if buf == "git ch", cur == 6 {
                    server.send(PopupStateCommand(visible: true, navigated: false), to: client)
                }
            }
            completions?.bufferChanged(session)
        case .key(_, let key):
            if ProcessInfo.processInfo.environment["SILL_DEBUG_AUTOINSERT"] != nil {
                NSLog("Sill: key=%@", key)
                if key == "tab" {
                    server.send(InsertCommand(del: 2, text: "checkout "), to: client)
                    server.send(PopupStateCommand(visible: false, navigated: false), to: client)
                }
                return
            }
            completions?.keyPressed(key, from: client)
        case .end:
            if let session = sessions[client] {
                completions?.lineEnded(session)
            }
        }
    }

    // MARK: - Windows

    @objc private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(updater: updater, specStore: specStore)
            if let window = settingsWindow?.window {
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: .main
                ) { [weak self] _ in
                    /* isVisible is still true inside willClose; re-evaluate
                       (and leave the Dock) on the next runloop cycle. */
                    DispatchQueue.main.async { self?.updateActivationPolicy() }
                }
            }
        }
        /* Accessory apps don't come forward on their own — the cooperative
           `activate()` is routinely refused for them, leaving the window
           behind the current app and without key focus. Force it, like the
           other Domus apps do. */
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
        updateActivationPolicy()
    }

    private func showOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = OnboardingWindowController()
        }
        onboardingWindow?.present()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        // The same width every Domus app uses.
        let item = NSStatusBar.system.statusItem(withLength: 20)
        item.button?.image = NSImage(
            systemSymbolName: "rectangle.and.text.magnifyingglass",
            accessibilityDescription: "Sill")
        item.menu = buildMenu()
        statusItem = item
        updateStatusItemVisibility()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let version =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let versionItem = NSMenuItem(title: "Sill \(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(updater.makeMenuItem())
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Sill", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func updateStatusItemVisibility() {
        statusItem?.isVisible = !AppPreferences.isMenuBarIconHidden
        updateActivationPolicy()
    }

    /* With the menu bar icon hidden, joining the Dock while Settings is open
       is the only way back into the app. */
    private func updateActivationPolicy() {
        let needsDock = AppPreferences.isMenuBarIconHidden
            && settingsWindow?.window?.isVisible == true
        NSApp.setActivationPolicy(needsDock ? .regular : .accessory)
    }

    /* Accessory apps get no menu bar, but ⌘W/⌘Q should still work when a
       window of ours is key (Settings, onboarding). */
    private func setUpMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: "Close Window", action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"))
        appMenu.addItem(NSMenuItem(
            title: "Quit Sill", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)
        NSApp.mainMenu = main
    }
}
