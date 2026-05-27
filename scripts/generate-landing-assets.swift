#!/usr/bin/env swift
import AppKit
import Foundation

// Generates the static assets used by docs/index.html:
//   docs/assets/icon-1024.png   → hero icon
//   docs/assets/icon-256.png    → small icon
//   docs/assets/favicon-64.png  → favicon
//   docs/assets/og-banner.png   → 1200×630 social-card image
// Run from project root: swift scripts/generate-landing-assets.swift

let here = FileManager.default.currentDirectoryPath
let assets = URL(fileURLWithPath: here).appendingPathComponent("docs/assets")
try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

// MARK: - Bitmap helpers

func makeRep(pixels: Int) -> (NSBitmapImageRep, NSGraphicsContext) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0
    )!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    return (rep, ctx)
}

func makeRectRep(width: Int, height: Int) -> (NSBitmapImageRep, NSGraphicsContext) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0
    )!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    return (rep, ctx)
}

func savePNG(_ rep: NSBitmapImageRep, to file: String) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError() }
    let url = assets.appendingPathComponent(file)
    try data.write(to: url)
    print("  wrote docs/assets/\(file)")
}

// MARK: - App icon (square, Big Sur-style squircle)

/// Draws the squircle icon at `origin` with side `s` into the CURRENT
/// NSGraphicsContext. Caller is responsible for setting the context up.
/// Used both to make the standalone icon-NNN.png AND to composite the icon
/// directly onto the banner (no intermediate bitmap = no alpha issues).
func drawIconContent(origin: NSPoint, side s: CGFloat) {
    let pad = s * 0.085
    let bgRect = NSRect(x: origin.x + pad, y: origin.y + pad,
                        width: s - 2*pad, height: s - 2*pad)
    let corner = bgRect.width * 0.2237
    let bg = NSBezierPath(roundedRect: bgRect, xRadius: corner, yRadius: corner)

    NSGradient(colors: [
        NSColor(red: 0.08, green: 0.16, blue: 0.42, alpha: 1),
        NSColor(red: 0.16, green: 0.42, blue: 0.88, alpha: 1),
        NSColor(red: 0.40, green: 0.78, blue: 1.00, alpha: 1),
    ])!.draw(in: bg, angle: -110)

    NSColor.white.withAlphaComponent(0.10).setStroke()
    let glow = NSBezierPath(roundedRect: bgRect.insetBy(dx: 1, dy: 1),
                            xRadius: corner, yRadius: corner)
    glow.lineWidth = max(1, s * 0.006)
    glow.stroke()

    let innerInset = s * 0.22
    let inner = NSRect(x: origin.x + innerInset, y: origin.y + innerInset,
                       width: s - 2*innerInset, height: s - 2*innerInset)
    let gap = max(s * 0.025, 1.5)
    let zc = s * 0.045
    let leftW = (inner.width - gap) * 0.6
    let rightW = (inner.width - gap) - leftW
    let halfH = (inner.height - gap) / 2
    let mainR = NSRect(x: inner.minX, y: inner.minY, width: leftW, height: inner.height)
    let topR  = NSRect(x: inner.minX + leftW + gap, y: inner.midY + gap/2, width: rightW, height: halfH)
    let botR  = NSRect(x: inner.minX + leftW + gap, y: inner.minY, width: rightW, height: halfH)

    func tile(_ r: NSRect, alpha: CGFloat) {
        NSColor(calibratedWhite: 1.0, alpha: alpha).setFill()
        NSBezierPath(roundedRect: r, xRadius: zc, yRadius: zc).fill()
        NSColor.white.withAlphaComponent(0.30).setStroke()
        let p = NSBezierPath(roundedRect: r, xRadius: zc, yRadius: zc)
        p.lineWidth = max(0.5, s * 0.003)
        p.stroke()
    }
    tile(mainR, alpha: 0.92)
    tile(topR,  alpha: 0.78)
    tile(botR,  alpha: 0.62)
}

/// Produces a standalone PNG of the icon (transparent outside the squircle).
func drawAppIcon(pixels: Int) -> NSBitmapImageRep {
    let (rep, ctx) = makeRep(pixels: pixels)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = ctx
    ctx.shouldAntialias = true
    ctx.imageInterpolation = .high
    let s = CGFloat(pixels)
    ctx.cgContext.clear(CGRect(x: 0, y: 0, width: s, height: s))
    drawIconContent(origin: .zero, side: s)
    return rep
}

// MARK: - Open Graph banner (1200×630)

func drawBanner() -> NSBitmapImageRep {
    let W = 1200, H = 630
    let (rep, ctx) = makeRectRep(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = ctx
    ctx.shouldAntialias = true
    ctx.imageInterpolation = .high

    let bounds = NSRect(x: 0, y: 0, width: W, height: H)

    // Dark Tokyo-Night-ish gradient background.
    NSGradient(colors: [
        NSColor(red: 0.03, green: 0.05, blue: 0.12, alpha: 1),
        NSColor(red: 0.06, green: 0.13, blue: 0.30, alpha: 1),
        NSColor(red: 0.10, green: 0.22, blue: 0.52, alpha: 1),
    ])!.draw(in: bounds, angle: -120)

    // Subtle grid in the background.
    NSColor.white.withAlphaComponent(0.04).setStroke()
    let path = NSBezierPath()
    path.lineWidth = 1
    for x in stride(from: 0, through: W, by: 48) {
        path.move(to: NSPoint(x: x, y: 0))
        path.line(to: NSPoint(x: x, y: H))
    }
    for y in stride(from: 0, through: H, by: 48) {
        path.move(to: NSPoint(x: 0, y: y))
        path.line(to: NSPoint(x: W, y: y))
    }
    path.stroke()

    // Left side: app icon, 380×380, centred vertically.
    // Draw it directly into the banner's context — compositing as a separate
    // NSBitmapImageRep replaces the destination's alpha channel and creates
    // a transparent rectangle around the squircle, which renders as a white
    // box on the social-card previews.
    let iconSize: CGFloat = 380
    let iconOriginX: CGFloat = 80
    let iconOriginY: CGFloat = (CGFloat(H) - iconSize) / 2
    drawIconContent(origin: NSPoint(x: iconOriginX, y: iconOriginY), side: iconSize)

    // Right side: title + tagline. Keep everything inside a 60-px safe area
    // from each edge — social-card UIs round the corners and crop the last
    // few pixels along the bottom (and top).
    let safeTop:    CGFloat = 80
    let safeBot:    CGFloat = 80
    let textOriginX: CGFloat = iconOriginX + iconSize + 60
    let textWidth:   CGFloat = CGFloat(W) - textOriginX - 60
    let textBlockHeight: CGFloat = CGFloat(H) - safeTop - safeBot
    let blockMinY:   CGFloat = safeBot
    let blockMidY:   CGFloat = blockMinY + textBlockHeight / 2

    let title = NSAttributedString(string: "MacWindowZone", attributes: [
        .font: NSFont.systemFont(ofSize: 72, weight: .heavy),
        .foregroundColor: NSColor.white,
        .kern: -1.5
    ])
    let titleSize = title.boundingRect(
        with: NSSize(width: textWidth, height: 200),
        options: [.usesLineFragmentOrigin]
    )

    let tagline = NSAttributedString(
        string: "Native macOS FancyZones.\nDefine zones. Snap windows.",
        attributes: [
            .font: NSFont.systemFont(ofSize: 26, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.80),
            .paragraphStyle: {
                let p = NSMutableParagraphStyle()
                p.lineSpacing = 4
                return p
            }()
        ]
    )
    let taglineSize = tagline.boundingRect(
        with: NSSize(width: textWidth, height: 200),
        options: [.usesLineFragmentOrigin]
    )

    let badge = NSAttributedString(
        string: "github.com/yfet/MacWindowZone",
        attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 18, weight: .medium),
            .foregroundColor: NSColor(red: 0.55, green: 0.85, blue: 1.00, alpha: 0.90)
        ]
    )
    let badgeSize = badge.boundingRect(
        with: NSSize(width: textWidth, height: 30),
        options: [.usesLineFragmentOrigin]
    )

    // Stack the three elements vertically with fixed spacing, then centre
    // the whole block inside the safe area.
    let gapTitleTagline: CGFloat = 16
    let gapTaglineBadge: CGFloat = 28
    let totalH = titleSize.height + gapTitleTagline + taglineSize.height + gapTaglineBadge + badgeSize.height
    var cursorY = blockMidY + totalH / 2 - titleSize.height  // top-of-title baseline (Cocoa y-up)

    title.draw(at: NSPoint(x: textOriginX, y: cursorY))
    cursorY -= gapTitleTagline + taglineSize.height
    tagline.draw(in: NSRect(x: textOriginX, y: cursorY,
                            width: textWidth, height: taglineSize.height + 4))
    cursorY -= gapTaglineBadge + badgeSize.height
    badge.draw(at: NSPoint(x: textOriginX, y: cursorY))

    return rep
}

// MARK: - Run

print("→ Generating landing-page assets")
try savePNG(drawAppIcon(pixels: 1024), to: "icon-1024.png")
try savePNG(drawAppIcon(pixels: 256),  to: "icon-256.png")
try savePNG(drawAppIcon(pixels: 64),   to: "favicon-64.png")
try savePNG(drawBanner(),              to: "og-banner.png")
print("✓ done")
