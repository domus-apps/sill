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
            /* No caret in this terminal's accessibility tree, so the grid the
               plugin measures is the only way to a real position. Until it
               arrives (a terminal still starting up answers its first query
               late) show nothing rather than pin the popup to a window
               corner far from the caret — the next keystroke carries the
               measurement. A terminal that says it will never answer
               (noGrid) does get the window anchor. */
            if let placement = gridCaret(appElement, session: session) { return placement }
            return session.noGrid ? windowFallback(appElement) : nil
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
       AXTextArea with no caret in it: the selected range is always empty and
       bounds-for-range is unsupported. So the popup is placed on the cell
       grid instead — the plugin measures the cell size in pixels (XTWINOPS
       16) and the pane's size (14) at each prompt, and the caret's cell
       comes from the pane's own text where the terminal exposes it
       (Ghostty) or from the plugin's cursor-position query (cmux).
       Ghostty pads the grid by 2pt (window-padding-x/y default) and hands
       any leftover to the far edges, so the grid's top-left corner is one
       padding in from the view's origin. */
    private static let defaultPadding: CGFloat = 2

    /* Two unknowns, one equation per axis: the view is the grid plus twice
       the padding plus a leftover of under one cell, which Ghostty parks on
       the right and bottom. Rather than split the difference, try the
       family default first — it is right unless the user configured
       something else, and then it is exact — and only estimate when the
       leftovers it implies are impossible. (Internal for the tests.) */
    static func padding(view: CGSize, text: CGSize, cell: CGSize) -> CGFloat {
        guard text.width > 0, text.height > 0, cell.width > 0, cell.height > 0
        else { return defaultPadding }
        let slackX = view.width - text.width
        let slackY = view.height - text.height
        guard slackX >= 0, slackY >= 0 else { return defaultPadding }
        let leftoverX = slackX - 2 * defaultPadding
        let leftoverY = slackY - 2 * defaultPadding
        if leftoverX >= 0, leftoverX < cell.width, leftoverY >= 0, leftoverY < cell.height {
            return defaultPadding
        }
        // Configured padding: it lies in ((slack − cell)/2, slack/2] on each
        // axis; the middle of where those overlap is the best guess.
        let low = max(0, max((slackX - cell.width) / 2, (slackY - cell.height) / 2))
        let high = min(slackX, slackY) / 2
        return high >= low ? (low + high) / 2 : high
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

        let (pane, lines) = choosePane(areas, textSize: textSize, cell: cell,
                                       session: session, in: appElement)
        let caret = caretCell(in: pane, lines: lines, session: session)
        let pad = padding(view: pane.frame.size, text: textSize, cell: cell)
        let rect = caret.map {
            CGRect(x: pane.frame.minX + pad + CGFloat($0.col - 1) * cell.width,
                   y: pane.frame.minY + pad + CGFloat($0.row - 1) * cell.height,
                   width: cell.width, height: cell.height)
        }
        debugLog(session: session, panes: areas, chosen: pane.frame, textSize: textSize,
                 cell: cell, pad: pad, caret: caret, rect: rect)
        guard let rect,
              pane.frame.insetBy(dx: -cell.width, dy: -cell.height).contains(rect.origin)
        else { return nil }
        return Placement(rect: flipped(rect), precise: true)
    }

    /* Placement is geometry from three sources — the terminal's report, the
       accessibility tree and the screen's own text — and when it lands in
       the wrong place only the numbers say which one was wrong. Create
       ~/.sill-grid-debug (the file the shell plugin logs to /tmp/sill-grid.log
       for) and every decision is appended to /tmp/sill-place.log. Checked
       once, at launch. */
    private static let placementLog: FileHandle? = {
        let marker = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".sill-grid-debug")
        guard FileManager.default.fileExists(atPath: marker.path) else { return nil }
        let path = "/tmp/sill-place.log"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
        return handle
    }()

    private static func debugLog(session: Session, panes: [(element: AXUIElement, frame: CGRect)],
                                 chosen: CGRect, textSize: CGSize, cell: CGSize, pad: CGFloat,
                                 caret: (row: Int, col: Int)?, rect: CGRect?) {
        guard let placementLog else { return }
        let list = panes.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))" }
        let line = """
            \(session.tty.split(separator: "/").last.map(String.init) ?? "?") buf=\"\(session.buffer)\" cur=\(session.cursor) grid=\(session.cols)x\(session.rows)             anchor=\(session.anchorRow),\(session.anchorCol) cell=\(cell.width)x\(cell.height)             text=\(textSize.width)x\(textSize.height) pad=\(pad)             panes=[\(list.joined(separator: " | "))]             chosen=\(Int(chosen.minX)),\(Int(chosen.minY)) \(Int(chosen.width))x\(Int(chosen.height))             caret=\(caret.map { "\($0.row),\($0.col)" } ?? "none")             rect=\(rect.map { "\(Int($0.minX)),\(Int($0.minY))" } ?? "none")

            """
        placementLog.write(Data(line.utf8))
    }

    /* Which pane is being typed in — the question splits make hard, and the
       one everything else rests on. Panes too small or too large for the
       grid the terminal reported are out. Among the rest, the surest sign is
       the text on screen: the pane showing the line being edited IS the
       shell's pane. Accessibility focus is only the tiebreak, because a
       terminal does not reliably move it when the active pane changes
       (measured: Ghostty pointed at a pane two splits away), and size alone
       cannot separate panes a few points apart. */
    private static func choosePane(_ areas: [(element: AXUIElement, frame: CGRect)],
                                   textSize: CGSize, cell: CGSize, session: Session,
                                   in appElement: AXUIElement)
        -> (pane: (element: AXUIElement, frame: CGRect), lines: [String]?)
    {
        let plausible = areas.filter { area in
            let slackX = area.frame.width - textSize.width
            let slackY = area.frame.height - textSize.height
            // The view is the grid plus padding plus a sub-cell leftover:
            // a little bigger on both axes, never smaller.
            return slackX >= 0 && slackX < cell.width * 4
                && slackY >= 0 && slackY < cell.height * 4
        }
        let pool = plausible.isEmpty ? areas : plausible
        if pool.count == 1 { return (pool[0], screenLines(of: pool[0].element)) }

        let tail = String(session.buffer.suffix(8))
        if !tail.isEmpty {
            let showing = pool.compactMap { pane -> ((element: AXUIElement, frame: CGRect), [String])? in
                guard let lines = screenLines(of: pane.element),
                      let last = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
                      lines[last].hasSuffix(tail)
                else { return nil }
                return (pane, lines)
            }
            if showing.count == 1 { return (showing[0].0, showing[0].1) }
            if showing.count > 1 {
                // Two panes showing the same line: focus, then the closest fit.
                let candidates = showing.map(\.0)
                if let focused = focusedPane(appElement, among: candidates),
                   let match = showing.first(where: { CFEqual($0.0.element, focused.element) }) {
                    return (match.0, match.1)
                }
                return (showing[0].0, showing[0].1)
            }
        }
        if let focused = focusedPane(appElement, among: pool) {
            return (focused, screenLines(of: focused.element))
        }
        let best = pool.min {
            fit($0.frame.size, to: textSize, cell: cell) < fit($1.frame.size, to: textSize, cell: cell)
        }!
        return (best, screenLines(of: best.element))
    }

    /// A pane's visible text, one entry per logical line.
    private static func screenLines(of element: AXUIElement) -> [String]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &value) == .success,
            let screen = value as? String, !screen.isEmpty
        else { return nil }
        return screen.components(separatedBy: "\n")
    }

    /* Where the caret sits in the pane's grid, in cells. The terminal's own
       text is the better source when it has any: Ghostty exposes the screen
       through accessibility, so the caret's row is simply the last line with
       something on it — no round trip, and it stays right when a split
       reflows the screen under a shell that measured its anchor at the last
       prompt. cmux exposes no text, so there the plugin's measured anchor
       carries it. */
    private static func caretCell(in pane: (element: AXUIElement, frame: CGRect),
                                  lines: [String]?, session: Session) -> (row: Int, col: Int)? {
        if let lines, let fromScreen = caretFromScreenText(lines, session: session) {
            return fromScreen
        }
        return session.anchorRow > 0 ? session.caretCell : nil
    }

    private static func caretFromScreenText(_ lines: [String],
                                            session: Session) -> (row: Int, col: Int)? {
        guard session.cols > 0,
              let last = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return nil }
        let line = lines[last]

        /* The line is the prompt plus what has been typed, so the caret is
           as many cells from its end as the buffer has characters after the
           cursor. Check the line really does end in the buffer before
           trusting it — a redraw Sill hasn't seen yet, or a pane showing
           something else entirely, must not move the popup. */
        let tail = String(session.buffer.suffix(8))
        if !tail.isEmpty, !line.hasSuffix(tail) { return nil }
        let behind = max(session.buffer.count - session.cursor, 0)
        let caretCells = displayWidth(of: line) - behind
        guard caretCells >= 0 else { return nil }

        /* Accessibility hands over logical lines; the grid shows them
           wrapped, so a line wider than the pane takes several rows and
           every row after it is pushed down (a login banner in a narrow
           split is exactly this). Count in rows, not lines. */
        let rowsBefore = lines[..<last].reduce(0) { $0 + wrappedRows(of: $1, cols: session.cols) }
        let caretRow = rowsBefore + caretCells / session.cols
        let total = rowsBefore + wrappedRows(of: line, cols: session.cols)

        /* Where those rows sit on screen: from the top while everything
           fits, and pinned to the bottom once the text is taller than the
           pane, because then the screen shows its tail. */
        let row = total <= session.rows
            ? caretRow + 1
            : session.rows - (total - 1 - caretRow)
        let col = caretCells % session.cols + 1
        guard row >= 1, row <= session.rows else { return nil }
        return (row, col)
    }

    static func wrappedRowsForTesting(_ line: String, cols: Int) -> Int {
        wrappedRows(of: line, cols: cols)
    }

    /// Rows a logical line takes on a grid `cols` wide — an empty line still
    /// takes one, and a line filling the width exactly does not spill over.
    private static func wrappedRows(of line: String, cols: Int) -> Int {
        let width = displayWidth(of: line)
        guard width > cols else { return 1 }
        return (width + cols - 1) / cols
    }

    /// Cells a string occupies: East Asian wide and fullwidth characters
    /// take two, everything else one.
    static func displayWidth(of text: String) -> Int {
        text.reduce(0) { width, character in
            guard let scalar = character.unicodeScalars.first else { return width }
            return width + (isWide(scalar) ? 2 : 1)
        }
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    /// The focused pane, when focus is on (or inside) one of these areas.
    private static func focusedPane(_ appElement: AXUIElement,
                                    among areas: [(element: AXUIElement, frame: CGRect)])
        -> (element: AXUIElement, frame: CGRect)?
    {
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
            let focused = focusedValue.map({ $0 as! AXUIElement })
        else { return nil }
        var node = focused
        for _ in 0..<4 {
            if let match = areas.first(where: { CFEqual($0.element, node) }) { return match }
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
