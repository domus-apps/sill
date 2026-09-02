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
            print("no focused element (\(result.rawValue))"); return
        }
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
}
