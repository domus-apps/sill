import AppKit
import ApplicationServices

/* Development-only (`Sill --probe-focus <bundle-id>`): what the frontmost
   terminal's focused element looks like through AX — used to decide how to
   place the popup for a new terminal. Kept tiny; never runs in normal use. */
enum AXProbe {
    static func run(bundleID: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { print("not running: \(bundleID)"); return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Electron/Chromium apps expose their web content only once an
        // assistive client asks for it.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        usleep(300_000)

        var focusedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue)
        guard result == .success, let focused = focusedValue.map({ $0 as! AXUIElement }) else {
            print("no focused element (\(result.rawValue))")
            dumpFocusedWindow(of: appElement)
            return
        }
        defer { dumpFocusedWindow(of: appElement) }
        func attr(_ name: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(focused, name as CFString, &v) == .success ? v : nil
        }
        print("role:", attr(kAXRoleAttribute) as? String ?? "?",
              "| subrole:", attr(kAXSubroleAttribute) as? String ?? "-",
              "| desc:", attr(kAXDescriptionAttribute) as? String ?? "-")
        var pos = CGPoint.zero, size = CGSize.zero
        if let p = attr(kAXPositionAttribute) { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
        if let s = attr(kAXSizeAttribute) { AXValueGetValue(s as! AXValue, .cgSize, &size) }
        print("frame:", pos, size)
        var names: CFArray?
        AXUIElementCopyParameterizedAttributeNames(focused, &names)
        print("parameterized:", (names as? [String] ?? []).joined(separator: ", "))
        if let rangeValue = attr(kAXSelectedTextRangeAttribute) {
            var range = CFRange()
            AXValueGetValue(rangeValue as! AXValue, .cfRange, &range)
            print("selected range:", range.location, range.length)
            var q = CFRange(location: max(range.location - 1, 0), length: 1)
            if let qv = AXValueCreate(.cfRange, &q) {
                var bounds: CFTypeRef?
                let r = AXUIElementCopyParameterizedAttributeValue(
                    focused, kAXBoundsForRangeParameterizedAttribute as CFString, qv, &bounds)
                var rect = CGRect.zero
                if r == .success, let b = bounds { AXValueGetValue(b as! AXValue, .cgRect, &rect) }
                print("bounds for range:", r.rawValue, rect)
            }
        } else {
            print("no selected text range")
        }
        // Ancestor chain: the terminal viewport's frame tells whether the
        // textarea sits on the row grid (offset = (top - viewportTop) mod cell).
        var node: AXUIElement = focused
        for depth in 1...8 {
            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parentValue) == .success,
                  let parent = parentValue.map({ $0 as! AXUIElement }) else { break }
            var r: CFTypeRef?, p: CFTypeRef?, sz: CFTypeRef?, d: CFTypeRef?
            AXUIElementCopyAttributeValue(parent, kAXRoleAttribute as CFString, &r)
            AXUIElementCopyAttributeValue(parent, kAXPositionAttribute as CFString, &p)
            AXUIElementCopyAttributeValue(parent, kAXSizeAttribute as CFString, &sz)
            AXUIElementCopyAttributeValue(parent, kAXDescriptionAttribute as CFString, &d)
            var pp = CGPoint.zero, ps = CGSize.zero
            if let p { AXValueGetValue(p as! AXValue, .cgPoint, &pp) }
            if let sz { AXValueGetValue(sz as! AXValue, .cgSize, &ps) }
            print("parent\(depth):", r as? String ?? "?", pp, ps, (d as? String ?? "").prefix(40))
            node = parent
        }
        // Where's the mouse-independent caret? Compare with window frame.
        var windowValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString,
                                         &windowValue) == .success,
           let window = windowValue.map({ $0 as! AXUIElement }) {
            var wp: CFTypeRef?, ws: CFTypeRef?
            var wpos = CGPoint.zero, wsize = CGSize.zero
            if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &wp) == .success {
                AXValueGetValue(wp as! AXValue, .cgPoint, &wpos)
            }
            if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &ws) == .success {
                AXValueGetValue(ws as! AXValue, .cgSize, &wsize)
            }
            print("window frame:", wpos, wsize)
        }
    }

    /// `Sill --probe-text <bundle-id>`: the terminal text area inside the
    /// focused window (found by role, so the app need not be frontmost) and
    /// what it — and its ancestors — say about the caret.
    static func probeText(bundleID: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { print("not running: \(bundleID)"); return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString,
                                            &windowValue) == .success,
              let window = windowValue.map({ $0 as! AXUIElement })
        else { print("no focused window"); return }
        var areas: [AXUIElement] = []
        collect(window, role: "AXTextArea", into: &areas, depth: 0)
        print("text areas:", areas.count)
        for area in areas {
            func attr(_ name: String) -> CFTypeRef? {
                var v: CFTypeRef?
                return AXUIElementCopyAttributeValue(area, name as CFString, &v) == .success ? v : nil
            }
            var pos = CGPoint.zero, size = CGSize.zero
            if let p = attr(kAXPositionAttribute) { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
            if let s = attr(kAXSizeAttribute) { AXValueGetValue(s as! AXValue, .cgSize, &size) }
            let text = attr(kAXValueAttribute) as? String ?? ""
            let lines = text.components(separatedBy: "\n")
            let lastFilled = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            print("  pane \(Int(pos.x)),\(Int(pos.y)) \(Int(size.width))x\(Int(size.height))",
                  "focused=\((attr(kAXFocusedAttribute) as? Bool) ?? false)",
                  "lines=\(lines.count) lastFilled=\(lastFilled.map { $0 + 1 } ?? 0)",
                  "last=[\(lastFilled.map { lines[$0] } ?? "")]")
        }
        for area in areas {
            func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
                var v: CFTypeRef?
                return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
            }
            var pos = CGPoint.zero, size = CGSize.zero
            if let p = attr(area, kAXPositionAttribute) { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
            if let sz = attr(area, kAXSizeAttribute) { AXValueGetValue(sz as! AXValue, .cgSize, &size) }
            print("== text area", pos, size, "focused=\((attr(area, kAXFocusedAttribute) as? Bool) ?? false)")
            let value = attr(area, kAXValueAttribute) as? String ?? ""
            let lines = value.components(separatedBy: "\n")
            print("value: \(value.count) chars, \(lines.count) lines; first:", lines.first?.prefix(60) ?? "", "| last non-empty:", lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?.prefix(60) ?? "")
            print("numberOfCharacters:", attr(area, kAXNumberOfCharactersAttribute) as? Int ?? -1,
                  "insertionPointLine:", attr(area, kAXInsertionPointLineNumberAttribute) as? Int ?? -1)
            var selected = CFRange()
            if let r = attr(area, kAXSelectedTextRangeAttribute) { AXValueGetValue(r as! AXValue, .cfRange, &selected) }
            print("selectedTextRange:", selected.location, selected.length)
            var visible = CFRange()
            if let r = attr(area, kAXVisibleCharacterRangeAttribute) { AXValueGetValue(r as! AXValue, .cfRange, &visible) }
            print("visibleCharacterRange:", visible.location, visible.length)
            // Try the text-geometry parameterized attributes on the area and its ancestors.
            var node = area
            for depth in 0..<4 {
                for (label, index) in [("0", 0), ("sel", selected.location), ("sel-1", max(selected.location - 1, 0))] {
                    var q = CFRange(location: index, length: 1)
                    guard let qv = AXValueCreate(.cfRange, &q) else { continue }
                    var bounds: CFTypeRef?
                    let r = AXUIElementCopyParameterizedAttributeValue(
                        node, kAXBoundsForRangeParameterizedAttribute as CFString, qv, &bounds)
                    var rect = CGRect.zero
                    if r == .success, let b = bounds { AXValueGetValue(b as! AXValue, .cgRect, &rect) }
                    print("  depth\(depth) boundsForRange(\(label)=\(index)):", r.rawValue, rect)
                }
                var lineValue: CFTypeRef?
                let lr = AXUIElementCopyParameterizedAttributeValue(
                    node, kAXLineForIndexParameterizedAttribute as CFString, selected.location as CFTypeRef, &lineValue)
                print("  depth\(depth) lineForIndex(sel):", lr.rawValue, lineValue as? Int ?? -1)
                var parentValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parentValue) == .success,
                      let parent = parentValue.map({ $0 as! AXUIElement }) else { break }
                node = parent
            }
        }
    }

    private static func collect(_ element: AXUIElement, role: String, into result: inout [AXUIElement], depth: Int) {
        guard depth < 8 else { return }
        var r: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &r)
        if r as? String == role { result.append(element) }
        var c: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &c) == .success,
              let children = c as? [AXUIElement] else { return }
        for child in children { collect(child, role: role, into: &result, depth: depth + 1) }
    }

    /// The focused window's element tree (roles, frames, text-ish
    /// attributes), a few levels deep — what a terminal without a focused
    /// element exposes at all.
    private static func dumpFocusedWindow(of appElement: AXUIElement) {
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString,
                                            &windowValue) == .success,
              let window = windowValue.map({ $0 as! AXUIElement })
        else { print("no focused window"); return }
        print("--- focused window tree:")
        dump(window, depth: 0)
    }

    private static func dump(_ element: AXUIElement, depth: Int) {
        guard depth < 6 else { return }
        func attr(_ name: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &v) == .success ? v : nil
        }
        var pos = CGPoint.zero, size = CGSize.zero
        if let p = attr(kAXPositionAttribute) { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
        if let s = attr(kAXSizeAttribute) { AXValueGetValue(s as! AXValue, .cgSize, &size) }
        var names: CFArray?
        AXUIElementCopyAttributeNames(element, &names)
        let all = (names as? [String]) ?? []
        let textish = all.filter { $0.contains("Text") || $0.contains("Range") || $0 == "AXValue" || $0 == "AXFocused" }
        var params: CFArray?
        AXUIElementCopyParameterizedAttributeNames(element, &params)
        let indent = String(repeating: "  ", count: depth)
        print("\(indent)\(attr(kAXRoleAttribute) as? String ?? "?")",
              "\(attr(kAXSubroleAttribute) as? String ?? "")",
              "\(Int(pos.x)),\(Int(pos.y)) \(Int(size.width))x\(Int(size.height))",
              "focused=\((attr(kAXFocusedAttribute) as? Bool) ?? false)",
              textish.isEmpty ? "" : "attrs=\(textish)",
              (params as? [String])?.isEmpty == false ? "params=\(params as! [String])" : "")
        guard let children = attr(kAXChildrenAttribute) as? [AXUIElement] else { return }
        for child in children.prefix(12) { dump(child, depth: depth + 1) }
    }
}
