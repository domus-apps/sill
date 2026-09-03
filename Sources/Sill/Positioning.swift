import AppKit
import ApplicationServices

/* Finds where to put the popup: the caret's screen rectangle, straight from
   the terminal's accessibility tree. Both supported terminals implement
   kAXBoundsForRangeParameterizedAttribute on their text areas (iTerm2's
   AX helper implements boundsForRange over screen+scrollback; Terminal.app's
   text view is a real AXTextArea), so no cell-size arithmetic is needed.
   When any step fails, fall back to the focused window's bottom-left. */
enum CaretLocator {
    struct Placement {
        var rect: CGRect     // AppKit screen coordinates (bottom-left origin)
        var precise: Bool    // false = window fallback, popup should offset
    }

    /// Electron apps we've already asked to expose their web content.
    private static var electronEnabled: Set<pid_t> = []

    static func locate(for session: Session) -> Placement? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication
        else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        if let bundleID = app.bundleIdentifier, SupportedTerminal.usesGrid(bundleID: bundleID) {
            return gridCaret(appElement, session: session) ?? windowFallback(appElement)
        }
        if let bundleID = app.bundleIdentifier, SupportedTerminal.isElectron(bundleID: bundleID),
           !electronEnabled.contains(app.processIdentifier) {
            /* Chromium builds its accessibility tree lazily; this attribute
               is the documented way for a client to switch it on. */
            AXUIElementSetAttributeValue(
                appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            electronEnabled.insert(app.processIdentifier)
        }

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
            let focused = focusedValue.map({ $0 as! AXUIElement })
        else { return windowFallback(appElement) }

        if let bundleID = app.bundleIdentifier, SupportedTerminal.isElectron(bundleID: bundleID) {
            /* xterm.js: bounds-for-range on the hidden textarea just echoes
               its frame, which sits off the row grid — use the grid instead. */
            return xtermCaret(focused) ?? windowFallback(appElement)
        }

        // The caret is the (empty) selected range's location.
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
            let rangeAX = rangeValue.map({ $0 as! AXValue })
        else { return windowFallback(appElement) }
        var range = CFRange()
        guard AXValueGetValue(rangeAX, .cfRange, &range) else {
            return windowFallback(appElement)
        }

        /* Ask for the bounds of the character BEFORE the caret (length 1 —
           a zero-length range returns an empty rect on some
           implementations); the caret itself is the cell just after it, and
           every placement is expressed as the caret's own cell. */
        let queriedPrecedingCell = range.location > 0
        var queryRange = CFRange(location: max(range.location - 1, 0), length: 1)
        guard let queryValue = AXValueCreate(.cfRange, &queryRange) else {
            return windowFallback(appElement)
        }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            focused, kAXBoundsForRangeParameterizedAttribute as CFString,
            queryValue, &boundsValue) == .success,
            let boundsAX = boundsValue.map({ $0 as! AXValue })
        else { return windowFallback(appElement) }
        var bounds = CGRect.zero
        guard AXValueGetValue(boundsAX, .cgRect, &bounds), bounds.height > 2,
              bounds.height < 100
        else { return windowFallback(appElement) }
        if queriedPrecedingCell { bounds.origin.x += bounds.width }

        return Placement(rect: flipped(bounds), precise: true)
    }

    /* xterm.js (VS Code's terminal) keeps a hidden, caret-sized textarea at
       the cursor so IME candidate windows appear there — it is the focused
       element while typing. Measured against a full-screen capture, its AX
       frame sits 8pt below the glyph row (VS Code's 8px spacing token), so
       the frame alone places the popup too low. Rather than a constant or a
       ratio — either could be wrong at another font size or zoom — snap to
       the row grid: the nearest ancestor whose height is a whole number of
       cells is the terminal's grid container, and rows start at its top. */
    private static func xtermCaret(_ element: AXUIElement) -> Placement? {
        guard let caret = frame(of: element),
              caret.height > 2, caret.height < 60, caret.width < 120
        else { return nil }
        let cell = caret.height
        var node = element
        for _ in 0..<8 {
            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString,
                                                &parentValue) == .success,
                  let parent = parentValue.map({ $0 as! AXUIElement })
            else { break }
            node = parent
            guard let container = frame(of: parent), container.height >= cell * 4 else { continue }
            let rows = container.height / cell
            guard abs(rows - rows.rounded()) < 0.05 else { continue }
            let rowIndex = floor((caret.minY - container.minY) / cell)
            let snapped = CGRect(x: caret.minX, y: container.minY + rowIndex * cell,
                                 width: caret.width, height: cell)
            return Placement(rect: flipped(snapped), precise: true)
        }
        // No grid-sized ancestor found — the frame itself is still better
        // than the window fallback.
        return Placement(rect: flipped(caret), precise: true)
    }

    /* Ghostty (and cmux, which embeds it) expose the terminal as an
       AXTextArea with the screen's text but no caret: the selected range is
       always empty and bounds-for-range is unsupported. The plugin measures
       the grid instead — where the prompt starts (CPR) and the cell size in
       pixels (XTWINOPS 16), asked in precmd, outside ZLE — and the caret is
       that cell inside the text area's frame. Ghostty pads the grid by 2pt
       (window-padding-x/y default) and hands any leftover to the far edges,
       so the top-left corner is one padding in from the view's origin.
       The padding is derived rather than assumed: the view is wider than
       the grid by twice the padding plus a leftover of under one cell, and
       the horizontal leftover is the tighter bound of the two. */
    private static let defaultPadding: CGFloat = 2

    private static func padding(view: CGSize, text: CGSize, cell: CGSize) -> CGFloat {
        guard text.width > 0, text.height > 0 else { return defaultPadding }
        let slack = min(view.width - text.width, view.height - text.height)
        guard slack >= 0 else { return defaultPadding }
        return min(slack / 2, cell.height)
    }

    private static func gridCaret(_ appElement: AXUIElement, session: Session) -> Placement? {
        guard let grid = session.grid else { return nil }
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
            let window = windowValue.map({ $0 as! AXUIElement })
        else { return nil }
        var areas: [(element: AXUIElement, frame: CGRect)] = []
        collectTextAreas(window, depth: 0, into: &areas)
        guard !areas.isEmpty else { return nil }

        let scale = NSScreen.screens.first(where: {
            $0.frame.intersects(flipped(areas[0].frame))
        })?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let cell = CGSize(width: grid.cellPixels.width / scale,
                          height: grid.cellPixels.height / scale)
        guard cell.width > 2, cell.height > 4 else { return nil }
        let textSize = CGSize(width: grid.textPixels.width / scale,
                              height: grid.textPixels.height / scale)

        /* Split panes are several text areas, and two of them can be exactly
           the same size (cmux's even splits), so size alone cannot say which
           one is being typed in — but the focused element can: with the
           terminal frontmost it IS that pane's text area. Size matching
           stays as the fallback for when focus sits elsewhere (a sidebar,
           a command palette). */
        let area = focusedTextArea(appElement, among: areas)
            ?? areas.min { a, b in
                fit(a.frame.size, to: textSize, cell: cell)
                    < fit(b.frame.size, to: textSize, cell: cell)
            }!.frame

        let caret = session.caretCell
        let pad = padding(view: area.size, text: textSize, cell: cell)
        let rect = CGRect(
            x: area.minX + pad + CGFloat(caret.col - 1) * cell.width,
            y: area.minY + pad + CGFloat(caret.row - 1) * cell.height,
            width: cell.width, height: cell.height)
        guard area.insetBy(dx: -cell.width, dy: -cell.height).contains(rect.origin) else { return nil }
        return Placement(rect: flipped(rect), precise: true)
    }

    /// The frame of the focused pane, when focus is on (or inside) one of
    /// the window's text areas.
    private static func focusedTextArea(_ appElement: AXUIElement,
                                        among areas: [(element: AXUIElement, frame: CGRect)])
        -> CGRect?
    {
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
            let focused = focusedValue.map({ $0 as! AXUIElement })
        else { return nil }
        var node = focused
        for _ in 0..<4 {
            if let match = areas.first(where: { CFEqual($0.element, node) }) {
                return match.frame
            }
            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString,
                                                &parentValue) == .success,
                  let parent = parentValue.map({ $0 as! AXUIElement })
            else { return nil }
            node = parent
        }
        return nil
    }

    /// How far a view is from the size the terminal reported (in cells);
    /// a view more than a cell off on either axis ranks after every
    /// closer one, and among ties the larger view wins.
    private static func fit(_ size: CGSize, to text: CGSize, cell: CGSize) -> CGFloat {
        guard text.width > 0, text.height > 0 else { return -size.width * size.height }
        let dx = abs(size.width - text.width) / cell.width
        let dy = abs(size.height - text.height) / cell.height
        return max(dx, dy) - size.width * size.height * 1e-9
    }

    private static func collectTextAreas(_ element: AXUIElement, depth: Int,
                                         into result: inout [(element: AXUIElement, frame: CGRect)]) {
        guard depth < 10 else { return }
        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        if roleValue as? String == kAXTextAreaRole, let frame = frame(of: element),
           frame.width > 40, frame.height > 40 {
            result.append((element, frame))
        }
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
            let children = childrenValue as? [AXUIElement]
        else { return }
        for child in children { collectTextAreas(child, depth: depth + 1, into: &result) }
    }

    /// An element's frame in AX (top-left origin) coordinates.
    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXUIElementCopyAttributeValue(
                element, kAXPositionAttribute as CFString, &positionValue) == .success,
            AXUIElementCopyAttributeValue(
                element, kAXSizeAttribute as CFString, &sizeValue) == .success,
            AXValueGetValue(positionValue.map({ $0 as! AXValue })!, .cgPoint, &position),
            AXValueGetValue(sizeValue.map({ $0 as! AXValue })!, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func windowFallback(_ appElement: AXUIElement) -> Placement? {
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
            let window = windowValue.map({ $0 as! AXUIElement })
        else { return nil }
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXUIElementCopyAttributeValue(
                window, kAXPositionAttribute as CFString, &positionValue) == .success,
            AXUIElementCopyAttributeValue(
                window, kAXSizeAttribute as CFString, &sizeValue) == .success,
            AXValueGetValue(positionValue.map({ $0 as! AXValue })!, .cgPoint, &position),
            AXValueGetValue(sizeValue.map({ $0 as! AXValue })!, .cgSize, &size)
        else { return nil }
        // Anchor near the window's bottom-left, above likely prompt rows.
        let rect = CGRect(x: position.x + 16, y: position.y + size.height - 60,
                          width: 8, height: 16)
        return Placement(rect: flipped(rect), precise: false)
    }

    /// AX rects are top-left-origin global coordinates; AppKit windows use
    /// bottom-left origin of the primary screen.
    private static func flipped(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        return CGRect(x: rect.origin.x,
                      y: primaryHeight - rect.origin.y - rect.height,
                      width: rect.width, height: rect.height)
    }
}
