import AppKit
import ApplicationServices
import SwiftUI

/* First-run walkthrough: what Sill does, the Accessibility grant, and the
   one-line shell integration. Deliberately uncloseable until finished —
   Sill does nothing at all without the integration, so an abandoned
   half-setup would just look broken. */
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let completedKey = "onboarding.completed"

    static var isCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }

    private let model = OnboardingModel()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        model.onFinish = { [weak self] in
            UserDefaults.standard.set(true, forKey: Self.completedKey)
            self?.close()
        }
        window.contentViewController = NSHostingController(
            rootView: OnboardingView(model: model))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        Self.isCompleted
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private final class OnboardingModel: ObservableObject {
    @Published var step = 0
    var onFinish: (() -> Void)?

    private var pollTimer: Timer?

    var accessibilityGranted: Bool { AXIsProcessTrusted() }
    var integrationInstalled: Bool { ShellIntegration.isInstalled }
    var integrationAvailable: Bool { ShellIntegration.isAvailable }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
        // TCC grants land without any notification — poll while waiting.
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            objectWillChange.send()
            if accessibilityGranted { pollTimer?.invalidate() }
        }
    }

    func installIntegration() {
        try? ShellIntegration.install()
        objectWillChange.send()
    }
}

private struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 28)
            switch model.step {
            case 0: welcome
            case 1: accessibility
            case 2: integration
            default: finish
            }
            Spacer()
            HStack {
                if model.step > 0 {
                    Button(L("Back")) { model.step -= 1 }
                }
                Spacer()
                nextButton
            }
            .padding(20)
        }
        .frame(width: 520, height: 420)
    }

    private var welcome: some View {
        page(symbol: "rectangle.and.text.magnifyingglass",
             title: L("Welcome to Sill"),
             body: L("As you type a command in Terminal, iTerm2, or VS Code, Sill shows what can come next — subcommands, options, files, branches — with a short description for each. Tab or Return inserts, ↑↓ choose, Esc dismisses."))
    }

    private var accessibility: some View {
        VStack(spacing: 12) {
            page(symbol: "accessibility",
                 title: L("Accessibility"),
                 body: L("Sill uses Accessibility for one thing: finding where you're typing so the popup appears at your cursor. Keys are handled inside your shell by the integration — nothing observes the keyboard."))
            if model.accessibilityGranted {
                Label(L("Granted"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button(L("Open System Settings…")) { model.requestAccessibility() }
            }
        }
    }

    private var integration: some View {
        VStack(spacing: 12) {
            page(symbol: "terminal",
                 title: L("Shell integration"),
                 body: L("Sill needs to see what you're typing. Installing adds a single guarded line to ~/.zshrc that streams the current command line to Sill — your file is backed up to ~/.zshrc.sill-backup first, and the switch in Settings removes it cleanly."))
            if !model.integrationAvailable {
                Text(L("Run the bundled app to install the integration."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.integrationInstalled {
                Label(L("Installed"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button(L("Install")) { model.installIntegration() }
            }
        }
    }

    private var finish: some View {
        page(symbol: "sparkles",
             title: L("Try it"),
             body: L("Open a new terminal tab (existing tabs don't have the integration yet) and type:\n\ngit ch\n\nThe popup appears as you type. Tab or Return inserts the highlighted completion; Esc dismisses it."))
    }

    private var nextButton: some View {
        Group {
            if model.step < 3 {
                Button(L("Continue")) { model.step += 1 }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(L("Done")) { model.onFinish?() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func page(symbol: String, title: String, body text: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 44)
        }
    }
}
