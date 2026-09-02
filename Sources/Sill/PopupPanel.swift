import AppKit
import SwiftUI

/* The completion popup: a non-activating panel that never takes key focus —
   the terminal keeps receiving every keystroke, and the shell integration's
   ZLE widgets steer the list (see sill.zsh). */
final class PopupPanel {
    private let panel: NSPanel
    private let model = PopupModel()
    /// Called when the user clicks a row.
    var onChoose: ((Suggestion) -> Void)?

    private static let rowHeight: CGFloat = 22
    private static let maxVisibleRows = 9
    private static let width: CGFloat = 360

    var isVisible: Bool { panel.isVisible }
    /// True once the user has moved the selection with the arrow keys —
    /// gates Return-to-insert so plain Return still runs the command.
    private(set) var userNavigated = false

    var selectedSuggestion: Suggestion? {
        guard model.suggestions.indices.contains(model.selectedIndex) else { return nil }
        return model.suggestions[model.selectedIndex]
    }


    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true

        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: PopupListView(model: model) { [weak self] suggestion in
            self?.onChoose?(suggestion)
        })
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
    }

    /// Shows (or repositions) the popup under `caret`, flipping above when
    /// the screen edge is in the way.
    /// Matches the popup to the terminal it floats over: a dark terminal on
    /// a light system gets a dark popup, and vice versa. nil follows the
    /// system appearance.
    func setPrefersDark(_ dark: Bool?) {
        panel.appearance = dark.flatMap { NSAppearance(named: $0 ? .darkAqua : .aqua) }
    }

    func show(_ suggestions: [Suggestion], at placement: CaretLocator.Placement) {
        let keepSelection = panel.isVisible
            && suggestions.first?.display == model.suggestions.first?.display
        model.suggestions = suggestions
        if !keepSelection {
            model.selectedIndex = 0
            userNavigated = false
        } else {
            model.selectedIndex = min(model.selectedIndex, suggestions.count - 1)
        }
        let rows = min(suggestions.count, Self.maxVisibleRows)
        let height = CGFloat(rows) * Self.rowHeight + 12
        panel.setFrame(NSRect(origin: origin(for: placement, height: height),
                              size: CGSize(width: Self.width, height: height)),
                       display: true)
        panel.orderFrontRegardless()
    }

    /// Below the caret line, flipped above it when the screen edge is in the
    /// way, and kept within the screen horizontally.
    private func origin(for placement: CaretLocator.Placement, height: CGFloat) -> CGPoint {
        let caret = placement.rect
        var origin = CGPoint(x: caret.minX, y: caret.minY - height - 4)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(caret.origin) })
            ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            if origin.y < visible.minY {  // no room below — flip above the line
                origin.y = caret.maxY + 4
            }
            origin.x = min(max(origin.x, visible.minX), visible.maxX - Self.width)
        }
        return origin
    }

    /// Repositions the visible popup under a new caret rectangle, leaving
    /// the list and selection alone.
    func move(to placement: CaretLocator.Placement) {
        guard panel.isVisible else { return }
        panel.setFrameOrigin(origin(for: placement, height: panel.frame.height))
    }

    func hide() {
        panel.orderOut(nil)
        model.suggestions = []
        userNavigated = false
    }

    func moveSelection(by delta: Int) {
        guard !model.suggestions.isEmpty else { return }
        let count = model.suggestions.count
        model.selectedIndex = (model.selectedIndex + delta + count) % count
        userNavigated = true
    }
}

private final class PopupModel: ObservableObject {
    @Published var suggestions: [Suggestion] = []
    @Published var selectedIndex = 0
}

private struct PopupListView: View {
    @ObservedObject var model: PopupModel
    var choose: (Suggestion) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.suggestions.enumerated()), id: \.offset) { index, suggestion in
                        PopupRow(suggestion: suggestion,
                                 isSelected: index == model.selectedIndex)
                            .id(index)
                            .onTapGesture { choose(suggestion) }
                    }
                }
                .padding(6)
            }
            .onChange(of: model.selectedIndex) { _, index in
                proxy.scrollTo(index)
            }
        }
        .environment(\.appearsActive, true)  // popup windows are never key
    }
}

private struct PopupRow: View {
    var suggestion: Suggestion
    var isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? .white : .secondary)
                .frame(width: 14)
            Text(suggestion.display)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
            if !suggestion.aliases.isEmpty {
                Text(suggestion.aliases.joined(separator: " "))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isSelected
                        ? AnyShapeStyle(.white.opacity(0.6)) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if !suggestion.detail.isEmpty {
                Text(suggestion.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected
                        ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color(nsColor: .controlAccentColor) : .clear)
        )
        .contentShape(Rectangle())
    }

    private var symbolName: String {
        switch suggestion.kind {
        case .subcommand: return "chevron.right.square"
        case .option: return "minus.square"
        case .argument: return "textformat.abc"
        case .file: return "doc"
        case .folder: return "folder"
        }
    }
}
