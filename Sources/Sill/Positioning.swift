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

    static func locate() -> Placement? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication
        else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
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

        // Ask for the bounds of the character at the caret (length 1 — a
        // zero-length range returns an empty rect on some implementations).
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
