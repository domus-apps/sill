import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

// MARK: - Window

enum SettingsPane: Int, CaseIterable {
    case general

    var title: String {
        switch self {
        case .general: L("General")
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        }
    }
}

/* System Settings-style window: full-height sidebar on the left, panes on
   the right. The style mask keeps all three traffic lights live (zoom stays
   disabled by macOS itself while the window is not resizable-by-content,
   matching native settings windows). */
final class SettingsWindowController: NSWindowController {
    private let splitViewController: SettingsSplitViewController

    init(updater: UpdaterController, specStore: SpecStore, derivedSpecs: DerivedSpecStore) {
        splitViewController = SettingsSplitViewController(
            updater: updater, specStore: specStore, derivedSpecs: derivedSpecs)
        let window = NSWindow(contentViewController: splitViewController)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        /* A toolbar (even an empty one) is required for the full-height
           sidebar look. The tall unified style centers the traffic lights
           in a roomier title bar (like Xcode's settings window) instead of
           pinning them to the top-left corner. */
        window.toolbarStyle = .unified
        let toolbar = NSToolbar()
        /* An empty toolbar defaults to .iconAndLabel, which inflates the
           unified title bar to 66pt; .iconOnly gives the standard 52pt that
           Xcode's settings window uses. */
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 640, height: 460))
        window.center()

        super.init(window: window)
        splitViewController.onPaneChange = { [weak window] pane in
            window?.title = pane.title
        }
        splitViewController.show(.general)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

final class SettingsSplitViewController: NSSplitViewController {
    var onPaneChange: ((SettingsPane) -> Void)?

    private let sidebar = SettingsSidebarViewController()
    private let paneContainer = NSViewController()
    private let generalPane: NSViewController
    private var currentPane: NSViewController?

    init(updater: UpdaterController, specStore: SpecStore, derivedSpecs: DerivedSpecStore) {
        /* The panes are SwiftUI grouped Forms — the exact section-header +
           rounded-box arrangement Xcode's settings use — hosted inside the
           AppKit split chrome. */
        let model = SettingsModel(updater: updater, specStore: specStore,
                                  derivedSpecs: derivedSpecs)
        generalPane = NSHostingController(rootView: GeneralSettingsView(model: model))
        super.init(nibName: nil, bundle: nil)

        paneContainer.view = NSView()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 160
        sidebarItem.canCollapse = false
        addSplitViewItem(sidebarItem)
        addSplitViewItem(NSSplitViewItem(viewController: paneContainer))

        sidebar.onSelect = { [weak self] pane in
            self?.show(pane)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ pane: SettingsPane) {
        let next: NSViewController =
            switch pane {
            case .general: generalPane
            }
        guard next !== currentPane else { return }

        if let currentPane {
            currentPane.view.removeFromSuperview()
            currentPane.removeFromParent()
        }
        paneContainer.addChild(next)
        next.view.translatesAutoresizingMaskIntoConstraints = false
        paneContainer.view.addSubview(next.view)
        NSLayoutConstraint.activate([
            next.view.topAnchor.constraint(equalTo: paneContainer.view.topAnchor),
            next.view.bottomAnchor.constraint(equalTo: paneContainer.view.bottomAnchor),
            next.view.leadingAnchor.constraint(equalTo: paneContainer.view.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: paneContainer.view.trailingAnchor),
        ])
        currentPane = next

        sidebar.select(pane)
        onPaneChange?(pane)
    }
}

// MARK: - Sidebar

final class SettingsSidebarViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate
{
    var onSelect: ((SettingsPane) -> Void)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    /* Extra top inset below the safe area. Zero, like Xcode's settings
       sidebar: the first row sits flush against the title bar boundary. */
    private static let scrollEdgeFadeClearance: CGFloat = 0

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pane"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowSizeStyle = .default
        tableView.allowsEmptySelection = false
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        /* Managed manually in viewDidLayout: the automatic inset stops at
           the safe area, which leaves the first row inside the fade. */
        scrollView.automaticallyAdjustsContentInsets = false
        view = scrollView

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.updateScrollEdgeFade()
        }
    }

    /* The soft scroll-edge fade (macOS 26) is not scroll-aware: its gradient
       backdrop hangs ~10pt below the title bar at all times, dimming a first
       row that sits flush against the boundary even when nothing is scrolled
       under the bar. Mirror Xcode's settings sidebar instead: fade only while
       content is actually scrolled under. The pocket is a private AppKit view
       (NSScrollPocket), so this is a defensive class-name lookup — if AppKit
       renames it, the system's default behavior simply returns. */
    private func updateScrollEdgeFade() {
        let restTop = -scrollView.contentInsets.top
        let atRest = scrollView.contentView.bounds.minY <= restTop + 0.5
        for subview in scrollView.subviews
        where String(describing: type(of: subview)) == "NSScrollPocket" {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                subview.animator().alphaValue = atRest ? 0 : 1
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        /* The pocket can appear after the first layout pass, so re-evaluate
           on every layout, not only when the inset changes. */
        defer { updateScrollEdgeFade() }
        let top = view.safeAreaInsets.top + Self.scrollEdgeFadeClearance
        guard scrollView.contentInsets.top != top else { return }
        let wasAtTop = scrollView.contentView.bounds.minY <= -scrollView.contentInsets.top
        scrollView.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
        if wasAtTop {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: -top))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func select(_ pane: SettingsPane) {
        guard tableView.selectedRow != pane.rawValue else { return }
        tableView.selectRowIndexes(IndexSet(integer: pane.rawValue), byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        SettingsPane.allCases.count
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let pane = SettingsPane(rawValue: row) else { return nil }

        let cell = NSTableCellView()
        let imageView = NSImageView(
            image: NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: nil)
                ?? NSImage())
        let textField = NSTextField(labelWithString: pane.title)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(imageView)
        cell.addSubview(textField)
        cell.imageView = imageView
        cell.textField = textField
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let pane = SettingsPane(rawValue: tableView.selectedRow) else { return }
        onSelect?(pane)
    }
}

// MARK: - SwiftUI bridge

/* One shared model: preferences live in UserDefaults (via AppPreferences);
   this object republishes their change notification so SwiftUI re-reads,
   and carries the pieces that aren't preferences (SMAppService, the
   updater, shell-integration state, the spec corpus). */
final class SettingsModel: ObservableObject {
    let updater: UpdaterController
    let specStore: SpecStore
    let derivedSpecs: DerivedSpecStore

    init(updater: UpdaterController, specStore: SpecStore, derivedSpecs: DerivedSpecStore) {
        self.updater = updater
        self.specStore = specStore
        self.derivedSpecs = derivedSpecs
        for name in [AppPreferences.changed, SpecStore.updated, SpecStore.statusChanged,
                     DerivedSpecStore.updated] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }

    /* SMAppService and the bundled integration script need a real app
       bundle; a bare `swift run` binary has neither. */
    var isBundledApp: Bool { Bundle.main.bundleIdentifier != nil }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Sill: launch-at-login change failed: \(error)")
            }
            objectWillChange.send()
        }
    }

    var integrationInstalled: Bool { ShellIntegration.isInstalled }
    var integrationAvailable: Bool { ShellIntegration.isAvailable }

    func toggleIntegration() {
        do {
            if integrationInstalled {
                try ShellIntegration.uninstall()
            } else {
                try ShellIntegration.install()
            }
        } catch {
            NSLog("Sill: shell integration change failed: \(error)")
        }
        objectWillChange.send()
    }

    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
        objectWillChange.send()
    }

    var specVersionLabel: String {
        SpecStore.installedVersion.map { L("Corpus %@", $0) } ?? L("Not downloaded yet")
    }

    var specStatus: SpecStore.Status { specStore.status }

    /// "Checked 3 minutes ago" — only when the last attempt reached the server.
    var specLastCheckLabel: String? {
        guard let date = SpecStore.lastCheck else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return L("Checked %@", formatter.localizedString(for: date, relativeTo: Date()))
    }

    func updateSpecs() {
        specStore.updateIfNeeded(force: true)
    }

    var learnedCount: Int { derivedSpecs.learnedCommands.count }

    var learnedLabel: String {
        switch learnedCount {
        case 0: L("Nothing learned yet")
        case 1: L("1 command learned")
        case let n: L("%d commands learned", n)
        }
    }

    func forgetLearned() {
        derivedSpecs.forgetAll()
        objectWillChange.send()
    }

    var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = (info?["CFBundleVersion"] as? String).map { " (\($0))" } ?? ""
        return version + build
    }

    func binding<Value>(
        _ get: @escaping () -> Value, _ set: @escaping (Value) -> Void
    ) -> Binding<Value> {
        Binding(get: get, set: set)
    }
}

// MARK: - General pane

struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Toggle(
                        L("Shell integration"),
                        isOn: model.binding({ model.integrationInstalled },
                                            { _ in model.toggleIntegration() })
                    )
                    .disabled(!model.integrationAvailable)
                    Text(model.integrationAvailable
                        ? L("Adds one line to ~/.zshrc that streams what you type to Sill. New terminal tabs pick it up; ~/.zshrc is backed up first.")
                        : L("Available in the bundled app only — `swift run` has no bundle to source the script from."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Toggle(
                        L("Complete command names"),
                        isOn: model.binding({ AppPreferences.completesCommandNames },
                                            { AppPreferences.completesCommandNames = $0 })
                    )
                    Text(L("Suggest the command itself from the first letter — installed commands Sill has definitions for, with what they do."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(L("Accessibility"))
                        Spacer()
                        if model.accessibilityGranted {
                            Label(L("Granted"), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .labelStyle(.titleAndIcon)
                        } else {
                            Button(L("Grant…")) { model.requestAccessibility() }
                        }
                    }
                    Text(L("Needed only to position the popup at your cursor. Steering keys are handled by the shell integration."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(L("Completions"))
            }

            Section {
                VStack(alignment: .leading, spacing: 3) {
                    /* The button stays put (disabled while busy) and the
                       spinner joins it, so the row never changes height. */
                    HStack {
                        Text(L("Completion specs"))
                        Spacer()
                        Text(model.specStatus.isBusy ? model.specStatus.label : model.specVersionLabel)
                            .foregroundStyle(.secondary)
                        if model.specStatus.isBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button(L("Update Now")) { model.updateSpecs() }
                            .disabled(model.specStatus.isBusy)
                    }
                    /* Outcome of the last attempt — success, "already
                       current", or why not — on a line that is always
                       reserved, so the text below doesn't shift. */
                    HStack(spacing: 4) {
                        if !model.specStatus.isBusy, !model.specStatus.label.isEmpty {
                            if case .failed = model.specStatus {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                            Text(model.specStatus.label)
                        } else if let checked = model.specLastCheckLabel, !model.specStatus.isBusy {
                            Text(checked)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(" ")
                        }
                    }
                    .font(.caption)
                    .frame(height: 14)
                    Text(L("Definitions for hundreds of CLIs, from the open-source withfig/autocomplete project. Refreshed daily in the background."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Toggle(
                        L("Learn unknown commands from --help"),
                        isOn: model.binding({ AppPreferences.learnsFromHelp },
                                            { AppPreferences.learnsFromHelp = $0 })
                    )
                    Text(L("Runs a command once with --help in the background to learn what its definition lacks, or all of it when there is none, and keeps that on this Mac. Real programs only — shell scripts are never run."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(model.learnedLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Forget All")) { model.forgetLearned() }
                            .controlSize(.small)
                            .disabled(model.learnedCount == 0)
                    }
                    .padding(.top, 2)
                }
            } header: {
                Text(L("Specs"))
            }

            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Toggle(
                        L("Launch at login"),
                        isOn: model.binding({ model.launchAtLogin }, { model.launchAtLogin = $0 })
                    )
                    .disabled(!model.isBundledApp)
                    if !model.isBundledApp {
                        Text(L("Available in the bundled app only."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(
                    L("Hide menu bar icon"),
                    isOn: model.binding({ AppPreferences.isMenuBarIconHidden },
                                        { AppPreferences.isMenuBarIconHidden = $0 })
                )
            } header: {
                Text(L("App"))
            }

            Section {
                HStack {
                    Text(L("Version %@", model.versionLabel))
                        .foregroundStyle(.secondary)
                    Spacer()
                    CheckForUpdatesButton(updater: model.updater)
                        .fixedSize()   // its own width, not the row's remainder
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Sparkle's menu-item validation doesn't reach SwiftUI buttons, so wrap
/// the AppKit button the UpdaterController vends.
private struct CheckForUpdatesButton: NSViewRepresentable {
    let updater: UpdaterController

    func makeNSView(context: Context) -> NSButton { updater.makeCheckButton() }
    func updateNSView(_ view: NSButton, context: Context) {}
}
