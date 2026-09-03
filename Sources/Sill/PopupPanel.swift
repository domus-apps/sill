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
    private static let cornerRadius: CGFloat = 8
    /* The gap between the panel's edge and a row's highlight. The popup is
       placed this far left of the caret so the highlight — not the panel's
       edge — lines up with what is being typed. */
    static let contentInset: CGFloat = 6

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
        /* The window-server shadow is what gives the card its native menu
           edge (a hairline rim along the rounded outline). It is computed
           from the window's alpha, so the content must be truly rounded —
           see maskImage below — and it is recomputed after every resize
           (invalidateShadow in show/move), or a stale square shadow lingers
           at the corners. */
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true

        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        /* The behind-window blur takes its shape from maskImage, not from
           the layer's corner radius — without this the blur is a rectangle
           whose corners peek out past the rounded card. */
        effect.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Self.cornerRadius
        effect.layer?.cornerCurve = .continuous
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

    /// A stretchable rounded-rect alpha mask for the visual effect view.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// The window server snapshots the shadow shape lazily; after a resize
    /// the old (square-cornered) one can persist. Ask for a fresh one once
    /// the new frame has been drawn.
    private func refreshShadow() {
        DispatchQueue.main.async { [panel] in
            panel.invalidateShadow()
        }
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
        refreshShadow()
    }

    /// Below the caret line, flipped above it when the screen edge is in the
    /// way, and kept within the screen horizontally.
    private func origin(for placement: CaretLocator.Placement, height: CGFloat) -> CGPoint {
        let caret = placement.rect
        var origin = CGPoint(x: caret.minX - Self.contentInset, y: caret.minY - height - 4)
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
        refreshShadow()
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
                .padding(.horizontal, PopupPanel.contentInset)
            }
            /* The vertical breathing room is a content margin rather than
               padding on the stack: scrollTo aligns a row to the edge of the
               scrollable region, and margins move that edge inward, so a row
               scrolled into view keeps its 6pt gap instead of touching the
               panel's edge. */
            .contentMargins(.vertical, PopupPanel.contentInset, for: .scrollContent)
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
            highlightedDisplay
                .font(.system(size: 12, design: .monospaced))
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

    /// The name with the characters the typed partial matched drawn bold in
    /// the text colour and the rest stepped down to the secondary colour, so
    /// the match stands out by weight and by tone. No accent tint: it lacks
    /// contrast on the dark menu material. With nothing matched (an empty
    /// partial) the whole name stays at full strength.
    private var highlightedDisplay: Text {
        let matched = Set(suggestion.matchedOffsets)
        let strong: AnyShapeStyle = isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary)
        let faint: AnyShapeStyle = matched.isEmpty ? strong
            : isSelected ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.secondary)
        var pieces = Text("")
        var run = ""
        var runMatched = false
        func flush() {
            guard !run.isEmpty else { return }
            let piece = runMatched
                ? Text(run).bold().foregroundStyle(strong)
                : Text(run).foregroundStyle(faint)
            pieces = Text("\(pieces)\(piece)")   // Text's + is deprecated on macOS 26
            run = ""
        }
        for (offset, character) in suggestion.display.enumerated() {
            let isMatch = matched.contains(offset)
            if isMatch != runMatched { flush(); runMatched = isMatch }
            run.append(character)
        }
        flush()
        return pieces
    }

    private var symbolName: String {
        switch suggestion.kind {
        case .command: return "terminal"
        case .subcommand: return "chevron.right.square"
        case .option: return "minus.square"
        // A value slot — branch, package, script name. Letter symbols like
        // textformat.abc are localized (Korean draws 가나다), so a glyph
        // without letters keeps the list identical in every language.
        case .argument: return "tag"
        case .file: return "doc"
        case .folder: return "folder"
        }
    }
}
