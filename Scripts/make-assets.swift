#!/usr/bin/env swift
// Generates the app icon (Assets/AppIcon.iconset/*.png + icon-1024.png) and
// the README banner (Assets/banner.png) programmatically, so the artwork is
// reproducible from source. Run: swift Scripts/make-assets.swift
// Then:  iconutil -c icns Assets/AppIcon.iconset -o Assets/AppIcon.icns
//
// Styled after macOS Tahoe's Liquid Glass icon language, sibling to the other
// Domus icons: the same continuous-curvature squircle, frosted-glass glyph
// (real gaussian-blurred backdrop via CoreImage), specular rim highlights,
// and soft layered shadows — here a terminal prompt (chevron and block
// cursor) with the suggestion card hanging off the cursor like a speech
// bubble, on a graphite gradient: the terminal's own dark, and the sill that
// offers the next word at the threshold.
//
// Graphite is the family's one deliberate exception to the saturated
// key-color rule: the terminal is black, and the icon says so.

import AppKit
import CoreImage
import SwiftUI

// MARK: - Helpers

let ciContext = CIContext()

func makeBitmap(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
}

func withContext(_ rep: NSBitmapImageRep, _ draw: (CGContext) -> Void) {
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    draw(ctx.cgContext)
    NSGraphicsContext.current = nil
}

func savePNG(_ rep: NSBitmapImageRep, _ path: String) {
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let rgb = CGColorSpaceCreateDeviceRGB()

func linearGradient(_ cg: CGContext, in path: CGPath, colors: [CGColor], from: CGPoint, to: CGPoint) {
    cg.saveGState()
    cg.addPath(path)
    cg.clip()
    let grad = CGGradient(colorsSpace: rgb, colors: colors as CFArray, locations: nil)!
    cg.drawLinearGradient(grad, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    cg.restoreGState()
}

/// The macOS app-icon silhouette: a continuous-corner rounded rect (straight
/// edges, Apple's smooth corner curve) — not a superellipse, whose sides
/// bulge. Radius fitted against the system's live icon mask (measured from
/// Calculator/Notes/Finder at 1024px: 214.5px on the 824px shape, ~0.16px RMS).
func squircle(in rect: CGRect) -> CGPath {
    Path(roundedRect: rect, cornerRadius: rect.width * (214.5 / 824), style: .continuous).cgPath
}

func gaussianBlur(_ image: CGImage, radius: CGFloat) -> CGImage {
    let ci = CIImage(cgImage: image)
    let blurred = ci.clampedToExtent()
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
        .cropped(to: ci.extent)
    return ciContext.createCGImage(blurred, from: ci.extent)!
}

// MARK: - Icon (designed in a 1024x1024 space, bottom-left origin)

let designRect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
let bgRect = CGRect(x: 100, y: 100, width: 824, height: 824) // standard macOS icon grid

/// Background layer: squircle, graphite gradient, top sheen, outer shadow.
func drawIconBackground(_ cg: CGContext) {
    let shape = squircle(in: bgRect)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 36, color: color(0x000000, 0.28))
    cg.addPath(shape)
    cg.setFillColor(color(0x475062))
    cg.fillPath()
    cg.restoreGState()

    /* Graphite — a cool slate rather than pure black, so the glass card
       still reads as glass on top of it, with the family's usual lightness
       drop (ΔL≈20%) from top to bottom. */
    linearGradient(
        cg, in: shape,
        colors: [color(0x6B7688), color(0x2E3745)],
        from: CGPoint(x: 512, y: bgRect.maxY), to: CGPoint(x: 512, y: bgRect.minY)
    )
    // Barely-there top light for depth
    linearGradient(
        cg, in: shape,
        colors: [color(0xFFFFFF, 0.1), color(0xFFFFFF, 0)],
        from: CGPoint(x: 512, y: bgRect.maxY), to: CGPoint(x: 512, y: bgRect.maxY - 320)
    )
}

/// Specular rim: a stroke around `path` that is bright on top, fading below.
func glassRim(_ cg: CGContext, around path: CGPath, width: CGFloat, bounds: CGRect, top: CGFloat, bottom: CGFloat) {
    let stroked = path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    linearGradient(
        cg, in: stroked,
        colors: [color(0xFFFFFF, top), color(0xFFFFFF, bottom)],
        from: CGPoint(x: bounds.midX, y: bounds.maxY), to: CGPoint(x: bounds.midX, y: bounds.minY)
    )
}

/// One frosted-glass shape: blurred backdrop, milky tint, specular rim.
func drawGlassShape(
    _ cg: CGContext, path: CGPath, bounds: CGRect, backdrop: CGImage,
    tintTop: CGFloat, tintBottom: CGFloat,
    rimWidth: CGFloat, rimTop: CGFloat, rimBottom: CGFloat,
    shadowBlur: CGFloat, shadowAlpha: CGFloat
) {
    // Drop shadow (opaque fill, replaced by the glass interior right after)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -shadowBlur * 0.4), blur: shadowBlur, color: color(0x000000, shadowAlpha))
    cg.addPath(path)
    cg.setFillColor(color(0xFFFFFF))
    cg.fillPath()
    cg.restoreGState()

    // Blurred backdrop + milky tint
    cg.saveGState()
    cg.addPath(path)
    cg.clip()
    cg.draw(backdrop, in: designRect)
    linearGradient(
        cg, in: path,
        colors: [color(0xFFFFFF, tintTop), color(0xFFFFFF, tintBottom)],
        from: CGPoint(x: bounds.midX, y: bounds.maxY), to: CGPoint(x: bounds.midX, y: bounds.minY)
    )
    cg.restoreGState()

    glassRim(cg, around: path, width: rimWidth, bounds: bounds, top: rimTop, bottom: rimBottom)
}

/* The glyph: a terminal prompt — the chevron and a block cursor — and,
   hanging off the cursor like a speech bubble, the suggestion card: a
   frosted-glass slab with a notch pointing up at the cursor, its first row
   filled in (the suggestion about to be taken). Set SILL_ICON_VARIANT=B to
   render the variant with a typed-word bar between chevron and cursor. */

let variantB = ProcessInfo.processInfo.environment["SILL_ICON_VARIANT"] == "B"

let promptY: CGFloat = 708          // vertical center of the prompt row
let chevronStroke: CGFloat = 36
let cursorRect = variantB
    ? CGRect(x: 610, y: 650, width: 78, height: 116)
    : CGRect(x: 476, y: 650, width: 78, height: 116)
let typedBar = CGRect(x: 400, y: 678, width: 176, height: 60)
/* Card bottom 262 … cursor top 766: the whole glyph is centered on the icon
   (group center 514 ≈ 512), with 44pt of air between cursor and notch. */
let cardRect = CGRect(x: 232, y: 262, width: 560, height: 300)
let cardCorner: CGFloat = 64
let notchHalfWidth: CGFloat = 46
let notchHeight: CGFloat = 44
let rowWidths: [CGFloat] = [440, 300]
let rowHeight: CGFloat = 74
let rowGap: CGFloat = 40
let rowInsetX: CGFloat = 60

/// The prompt chevron ">" as a filled shape (a thick, round-capped stroke).
func chevronPath() -> CGPath {
    let x0: CGFloat = variantB ? 268 : 320
    let line = CGMutablePath()
    line.move(to: CGPoint(x: x0, y: promptY + 58))
    line.addLine(to: CGPoint(x: x0 + 70, y: promptY))
    line.addLine(to: CGPoint(x: x0, y: promptY - 58))
    return line.copy(strokingWithWidth: chevronStroke, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

/// One continuous outline — the notch is part of the top edge, not a second
/// subpath laid over it, so the specular rim has no inner seam to trace
/// where a separate triangle would meet the rectangle.
func cardPath() -> CGPath {
    let r = cardRect, c = cardCorner, nx = cursorRect.midX
    let path = CGMutablePath()
    path.move(to: CGPoint(x: r.minX + c, y: r.maxY))
    path.addLine(to: CGPoint(x: nx - notchHalfWidth, y: r.maxY))
    path.addLine(to: CGPoint(x: nx, y: r.maxY + notchHeight))
    path.addLine(to: CGPoint(x: nx + notchHalfWidth, y: r.maxY))
    path.addLine(to: CGPoint(x: r.maxX - c, y: r.maxY))
    path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY),
                tangent2End: CGPoint(x: r.maxX, y: r.maxY - c), radius: c)
    path.addLine(to: CGPoint(x: r.maxX, y: r.minY + c))
    path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY),
                tangent2End: CGPoint(x: r.maxX - c, y: r.minY), radius: c)
    path.addLine(to: CGPoint(x: r.minX + c, y: r.minY))
    path.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY),
                tangent2End: CGPoint(x: r.minX, y: r.minY + c), radius: c)
    path.addLine(to: CGPoint(x: r.minX, y: r.maxY - c))
    path.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY),
                tangent2End: CGPoint(x: r.minX + c, y: r.maxY), radius: c)
    path.closeSubpath()
    return path
}

/// The card's bounds including the notch — what the glass rim is built for.
let cardBounds = CGRect(
    x: cardRect.minX, y: cardRect.minY, width: cardRect.width,
    height: cardRect.height + notchHeight)

func rowRect(_ index: Int) -> CGRect {
    // The two rows sit centered in the card's height.
    let contentHeight = 2 * rowHeight + rowGap
    let top = cardRect.maxY - (cardRect.height - contentHeight) / 2 - rowHeight
    return CGRect(
        x: cardRect.minX + rowInsetX,
        y: top - CGFloat(index) * (rowHeight + rowGap),
        width: rowWidths[index], height: rowHeight)
}

func capsule(_ rect: CGRect) -> CGPath {
    let radius = min(rect.width, rect.height) / 2
    return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func cursorPath() -> CGPath {
    CGPath(roundedRect: cursorRect, cornerWidth: 14, cornerHeight: 14, transform: nil)
}

func drawGlyph(_ cg: CGContext, backdrop: CGImage, boost: Bool) {
    // Prompt chevron and block cursor — solid white, the brightest elements.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: color(0x000000, 0.35))
    cg.addPath(chevronPath())
    cg.addPath(cursorPath())
    cg.setFillColor(color(0xFFFFFF))
    cg.fillPath()
    cg.restoreGState()
    if variantB {
        drawGlassShape(
            cg, path: capsule(typedBar), bounds: typedBar, backdrop: backdrop,
            tintTop: boost ? 0.66 : 0.5, tintBottom: boost ? 0.52 : 0.36,
            rimWidth: 5, rimTop: 0.8, rimBottom: 0.2, shadowBlur: 26, shadowAlpha: 0.24)
    }

    // The suggestion card, notch included, as one glass shape.
    drawGlassShape(
        cg, path: cardPath(), bounds: cardBounds, backdrop: backdrop,
        tintTop: boost ? 0.8 : 0.68, tintBottom: boost ? 0.64 : 0.48,
        rimWidth: 6, rimTop: 0.9, rimBottom: 0.22,
        shadowBlur: 40, shadowAlpha: 0.32
    )
    // Rows: the selected first row solid, the second translucent.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x000000, 0.22))
    cg.addPath(capsule(rowRect(0)))
    cg.setFillColor(color(0xFFFFFF))
    cg.fillPath()
    cg.restoreGState()
    cg.setFillColor(color(0xFFFFFF, 0.42))
    cg.addPath(capsule(rowRect(1)))
    cg.fillPath()
}

/// Renders the complete icon at `px` and returns the bitmap.
func makeIcon(px: Int) -> NSBitmapImageRep {
    let scale = CGFloat(px) / 1024
    let blurRadius = max(36 * scale, 1)
    // Small sizes: more opaque glass keeps the glyph legible in the menu bar /
    // Dock, where the frosted subtlety would just vanish.
    let boost = px <= 64

    let shape = squircle(in: bgRect)

    /* Clip the glyph to the squircle, and at small sizes optically enlarge
       it (like Apple's small-size icon variants) so it stays prominent in
       the menu bar / Dock. */
    func clippedGlyph(_ cg: CGContext, _ body: (CGContext) -> Void) {
        cg.saveGState()
        cg.addPath(shape)
        cg.clip()
        if boost {
            cg.translateBy(x: 512, y: 512)
            cg.scaleBy(x: 1.14, y: 1.14)
            cg.translateBy(x: -512, y: -512)
        }
        body(cg)
        cg.restoreGState()
    }

    // Scene 1: the background the glass will frost over.
    let bgRep = makeBitmap(px, px)
    withContext(bgRep) { cg in
        cg.scaleBy(x: scale, y: scale)
        drawIconBackground(cg)
    }
    let backdrop = gaussianBlur(bgRep.cgImage!, radius: blurRadius)

    let rep = makeBitmap(px, px)
    withContext(rep) { cg in
        cg.scaleBy(x: scale, y: scale)
        cg.draw(bgRep.cgImage!, in: designRect)
        clippedGlyph(cg) { drawGlyph($0, backdrop: backdrop, boost: boost) }
    }
    return rep
}

// MARK: - Icon Composer layers (macOS 26+ .icon document)

/* The .icon format gets dark/clear/tinted appearances for free: we ship flat
   transparent layers plus a background fill, and the system renders the
   Liquid Glass treatment (and the dark background) at runtime. In a .icon
   document the 1024pt canvas IS the icon shape — the system adds its own
   margins — whereas our design space puts the squircle at 100..924, so the
   glyph is remapped to land at the same visual position. */
func makeIconLayer(_ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = makeBitmap(1024, 1024)
    withContext(rep) { cg in
        cg.scaleBy(x: 1024 / 824, y: 1024 / 824)
        cg.translateBy(x: -100, y: -100)
        draw(cg)
    }
    return rep
}

func drawFlatGlyph(_ cg: CGContext) {
    /* Card slightly translucent, prompt/cursor/selected row solid — the same
       two-tone reading the rendered icon has, flattened for Icon Composer.
       The second row is a deeper gray-tinted white rather than a hole. */
    cg.setFillColor(color(0xFFFFFF, 0.74))
    cg.addPath(cardPath())
    if variantB { cg.addPath(capsule(typedBar)) }
    cg.fillPath()
    cg.setFillColor(color(0xFFFFFF))
    cg.addPath(chevronPath())
    cg.addPath(cursorPath())
    cg.addPath(capsule(rowRect(0)))
    cg.fillPath()
    cg.setFillColor(color(0xCFD5DE))
    cg.addPath(capsule(rowRect(1)))
    cg.fillPath()
}

// MARK: - Shared banner elements

/// A faint four-point twinkle, the same quiet sky the sibling banners share.
func sparklePath(center: CGPoint, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let n = CGPoint(x: center.x, y: center.y + radius)
    let e = CGPoint(x: center.x + radius, y: center.y)
    let s = CGPoint(x: center.x, y: center.y - radius)
    let w = CGPoint(x: center.x - radius, y: center.y)
    path.move(to: n)
    path.addQuadCurve(to: e, control: center)
    path.addQuadCurve(to: s, control: center)
    path.addQuadCurve(to: w, control: center)
    path.addQuadCurve(to: n, control: center)
    path.closeSubpath()
    return path
}

func drawSparkles(_ cg: CGContext, _ sparkles: [(x: CGFloat, y: CGFloat, r: CGFloat, a: CGFloat)]) {
    for s in sparkles {
        cg.addPath(sparklePath(center: CGPoint(x: s.x, y: s.y), radius: s.r))
        cg.setFillColor(color(0xFFFFFF, s.a))
        cg.fillPath()
    }
}

let pillLabelColor = NSColor(srgbRed: 0.88, green: 0.91, blue: 0.95, alpha: 1)
let taglineColor = NSColor(srgbRed: 0.78, green: 0.83, blue: 0.9, alpha: 1)
let tagline = "Autocomplete for your terminal"

func pillText(_ label: String, fontSize: CGFloat) -> NSAttributedString {
    NSAttributedString(string: label, attributes: [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
        .foregroundColor: pillLabelColor,
    ])
}

func pillWidth(label: String, fontSize: CGFloat, pad: CGFloat) -> CGFloat {
    pad + pillText(label, fontSize: fontSize).size().width + pad
}

/// One text pill; returns its maxX. Width is computed, never measured by
/// drawing — a nested bitmap context would clear NSGraphicsContext.current
/// mid-render and silently drop every text draw after it.
@discardableResult
func drawPill(
    _ cg: CGContext, x: CGFloat, y: CGFloat, height: CGFloat, label: String,
    fontSize: CGFloat, pad: CGFloat
) -> CGFloat {
    let text = pillText(label, fontSize: fontSize)
    let pill = CGRect(
        x: x, y: y, width: pillWidth(label: label, fontSize: fontSize, pad: pad), height: height)

    cg.addPath(CGPath(roundedRect: pill, cornerWidth: height / 4, cornerHeight: height / 4, transform: nil))
    cg.setFillColor(color(0xFFFFFF, 0.07))
    cg.fillPath()
    cg.addPath(CGPath(roundedRect: pill.insetBy(dx: 1.5, dy: 1.5), cornerWidth: height / 4 - 1, cornerHeight: height / 4 - 1, transform: nil))
    cg.setStrokeColor(color(0xFFFFFF, 0.14))
    cg.setLineWidth(2.5)
    cg.strokePath()

    text.draw(at: NSPoint(
        x: pill.minX + pad, y: pill.minY + (pill.height - text.size().height) / 2))
    return pill.maxX
}

let pillLabels = ["Hundreds of CLIs", "Tab to insert", "Terminal · iTerm2 · VS Code"]

// MARK: - Banner (1800 x 600)

func drawBanner(_ cg: CGContext, icon: CGImage) {
    let canvas = CGRect(x: 0, y: 0, width: 1800, height: 600)
    let frame = CGPath(roundedRect: canvas, cornerWidth: 40, cornerHeight: 40, transform: nil)
    /* The family rule: each banner is a deep tint of the app's own key
       color (Coffer 122E24, Jamb 0E2C2E, Louver 1C300E) — here Sill's
       graphite, darkened. */
    linearGradient(
        cg, in: frame,
        colors: [color(0x232A35), color(0x0F1319)],
        from: CGPoint(x: canvas.midX, y: canvas.maxY), to: CGPoint(x: canvas.midX, y: canvas.minY)
    )

    // A faint night sky on the right
    cg.saveGState()
    cg.addPath(frame)
    cg.clip()
    drawSparkles(cg, [
        (1420, 470, 26, 0.07), (1580, 320, 40, 0.06), (1710, 480, 18, 0.06),
        (1500, 130, 22, 0.05), (1680, 190, 30, 0.07), (1350, 250, 14, 0.05),
    ])
    cg.restoreGState()

    // App icon on the left
    cg.draw(icon, in: CGRect(x: 100, y: 118, width: 364, height: 364))

    // Wordmark + tagline
    let title = NSAttributedString(string: "Sill", attributes: [
        .font: NSFont.systemFont(ofSize: 130, weight: .bold),
        .foregroundColor: NSColor.white,
    ])
    title.draw(at: NSPoint(x: 520, y: 300))

    let taglineText = NSAttributedString(string: tagline, attributes: [
        .font: NSFont.systemFont(ofSize: 46, weight: .medium),
        .foregroundColor: taglineColor,
    ])
    taglineText.draw(at: NSPoint(x: 528, y: 218))

    var x: CGFloat = 528
    for label in pillLabels {
        x = drawPill(cg, x: x, y: 108, height: 72, label: label, fontSize: 36, pad: 28) + 22
    }
}

// MARK: - GitHub social preview (1280 x 640 design space, rendered @2x)

func drawSocialPreview(_ cg: CGContext, icon: CGImage) {
    let canvas = CGRect(x: 0, y: 0, width: 1280, height: 640)
    // Full bleed — GitHub renders the preview edge to edge and rounds the
    // corners itself, so transparent corners would show through as white.
    linearGradient(
        cg, in: CGPath(rect: canvas, transform: nil),
        colors: [color(0x2C3440), color(0x0F1319)],
        from: CGPoint(x: canvas.midX, y: canvas.maxY), to: CGPoint(x: canvas.midX, y: canvas.minY)
    )

    // Faint night sky drifting off the corners
    drawSparkles(cg, [
        (90, 560, 26, 0.06), (230, 620, 16, 0.05), (170, 480, 12, 0.05),
        (1160, 120, 30, 0.06), (1060, 40, 18, 0.05), (1230, 260, 14, 0.05),
    ])

    func drawCentered(_ text: NSAttributedString, y: CGFloat) {
        text.draw(at: NSPoint(x: canvas.midX - text.size().width / 2, y: y))
    }

    // Centered stack: icon, wordmark, tagline, feature pills — sized up so
    // the card stays legible at the small sizes link previews render at.
    cg.draw(icon, in: CGRect(x: canvas.midX - 125, y: 355, width: 250, height: 250))

    drawCentered(
        NSAttributedString(string: "Sill", attributes: [
            .font: NSFont.systemFont(ofSize: 100, weight: .bold),
            .foregroundColor: NSColor.white,
        ]), y: 238)

    drawCentered(
        NSAttributedString(string: tagline, attributes: [
            .font: NSFont.systemFont(ofSize: 38, weight: .medium),
            .foregroundColor: taglineColor,
        ]), y: 176)

    let gap: CGFloat = 16
    let widths = pillLabels.map { pillWidth(label: $0, fontSize: 30, pad: 24) }
    var x = canvas.midX - (widths.reduce(0, +) + gap * CGFloat(pillLabels.count - 1)) / 2
    for (label, width) in zip(pillLabels, widths) {
        drawPill(cg, x: x, y: 82, height: 62, label: label, fontSize: 30, pad: 24)
        x += width + gap
    }
}

// MARK: - Main

let fm = FileManager.default
try? fm.createDirectory(atPath: "Assets/AppIcon.iconset", withIntermediateDirectories: true)

// Iconset: render each size directly from vectors (crisper than downscaling)
let iconSizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in iconSizes {
    savePNG(makeIcon(px: px), "Assets/AppIcon.iconset/\(name).png")
}

let master = makeIcon(px: 1024)
savePNG(master, "Assets/icon-1024.png")

// Icon Composer layer for the macOS 26+ .icon document (front only — the
// fill gradient in icon.json is the whole background)
try? fm.createDirectory(atPath: "Assets/AppIcon.icon/Assets", withIntermediateDirectories: true)
savePNG(makeIconLayer(drawFlatGlyph), "Assets/AppIcon.icon/Assets/front.png")

let bannerIcon = makeIcon(px: 728).cgImage!
let banner = makeBitmap(1800, 600)
withContext(banner) { drawBanner($0, icon: bannerIcon) }
savePNG(banner, "Assets/banner.png")

// GitHub social preview: exactly 1280x640, GitHub's recommended size.
let og = makeBitmap(1280, 640)
withContext(og) { cg in
    drawSocialPreview(cg, icon: bannerIcon)
}
savePNG(og, "Assets/og-image.png")
