import AppKit

/* The menu bar glyph: the app icon's motif, a terminal prompt (chevron and
   block cursor) with the suggestion card hanging off the cursor, drawn as
   a template image so it takes the menu bar's tint and stays crisp at any
   scale. In an 18×18 point space, the group is centered on (9, 9); the card
   is an outline so its rows read at this size. */
enum MenuBarIcon {
    static func prompt() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            /* Bigger and simpler than the icon: one row instead of two, and
               the prompt thick enough to read at menu bar size. */
            // Prompt chevron ">"
            let chevron = NSBezierPath()
            chevron.move(to: NSPoint(x: 3.4, y: 16))
            chevron.line(to: NSPoint(x: 6, y: 13.6))
            chevron.line(to: NSPoint(x: 3.4, y: 11.2))
            chevron.lineWidth = 2
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            chevron.stroke()

            // Block cursor
            NSBezierPath(
                roundedRect: NSRect(x: 8.2, y: 11.2, width: 2.6, height: 4.8), xRadius: 0.6, yRadius: 0.6
            ).fill()

            // Suggestion card: one outline with the notch pointing up at the cursor
            let r = NSRect(x: 2, y: 1.5, width: 14, height: 7)
            let c: CGFloat = 2, nx: CGFloat = 9.5, notchHalf: CGFloat = 1.4, notchHeight: CGFloat = 1.3
            let card = NSBezierPath()
            card.move(to: NSPoint(x: r.minX + c, y: r.maxY))
            card.line(to: NSPoint(x: nx - notchHalf, y: r.maxY))
            card.line(to: NSPoint(x: nx, y: r.maxY + notchHeight))
            card.line(to: NSPoint(x: nx + notchHalf, y: r.maxY))
            card.line(to: NSPoint(x: r.maxX - c, y: r.maxY))
            card.appendArc(from: NSPoint(x: r.maxX, y: r.maxY), to: NSPoint(x: r.maxX, y: r.maxY - c), radius: c)
            card.line(to: NSPoint(x: r.maxX, y: r.minY + c))
            card.appendArc(from: NSPoint(x: r.maxX, y: r.minY), to: NSPoint(x: r.maxX - c, y: r.minY), radius: c)
            card.line(to: NSPoint(x: r.minX + c, y: r.minY))
            card.appendArc(from: NSPoint(x: r.minX, y: r.minY), to: NSPoint(x: r.minX, y: r.minY + c), radius: c)
            card.line(to: NSPoint(x: r.minX, y: r.maxY - c))
            card.appendArc(from: NSPoint(x: r.minX, y: r.maxY), to: NSPoint(x: r.minX + c, y: r.maxY), radius: c)
            card.close()
            card.lineWidth = 1.6
            card.lineJoinStyle = .round
            card.stroke()

            // The suggestion about to be taken
            NSBezierPath(
                roundedRect: NSRect(x: 4.6, y: 4.1, width: 8.8, height: 1.8), xRadius: 0.9, yRadius: 0.9
            ).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Sill"
        return image
    }
}
