#!/usr/bin/env swift
import AppKit
import Foundation

// Generates AppResources/AppIcon.icns from a programmatically drawn
// macOS Big Sur-style icon (rounded squircle with a priority-grid motif).
// Run from the project root:  swift scripts/generate-icon.swift

let here = FileManager.default.currentDirectoryPath
let appResources = URL(fileURLWithPath: here).appendingPathComponent("AppResources")
let iconsetDir = appResources.appendingPathComponent("AppIcon.iconset")
let icnsURL = appResources.appendingPathComponent("AppIcon.icns")

try? FileManager.default.createDirectory(at: appResources, withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

// Apple's iconset naming convention (1x and @2x variants).
let entries: [(name: String, pixels: Int)] = [
    ("icon_16x16.png",        16),
    ("icon_16x16@2x.png",     32),
    ("icon_32x32.png",        32),
    ("icon_32x32@2x.png",     64),
    ("icon_128x128.png",     128),
    ("icon_128x128@2x.png",  256),
    ("icon_256x256.png",     256),
    ("icon_256x256@2x.png",  512),
    ("icon_512x512.png",     512),
    ("icon_512x512@2x.png", 1024),
]

func drawIcon(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.shouldAntialias = true
    ctx.imageInterpolation = .high

    let s = CGFloat(pixels)

    // Rounded squircle backdrop with Big Sur padding (~8.5% inset).
    let pad = s * 0.085
    let bgRect = NSRect(x: pad, y: pad, width: s - 2*pad, height: s - 2*pad)
    let cornerRadius = bgRect.width * 0.2237  // Apple squircle approximation
    let bg = NSBezierPath(roundedRect: bgRect, xRadius: cornerRadius, yRadius: cornerRadius)

    // Background gradient — Tokyo-Night-ish blue → teal.
    let gradient = NSGradient(colors: [
        NSColor(red: 0.08, green: 0.16, blue: 0.42, alpha: 1),
        NSColor(red: 0.16, green: 0.42, blue: 0.88, alpha: 1),
        NSColor(red: 0.40, green: 0.78, blue: 1.00, alpha: 1),
    ])!
    gradient.draw(in: bg, angle: -110)

    // Subtle inner glow ring.
    NSColor.white.withAlphaComponent(0.10).setStroke()
    let glow = NSBezierPath(roundedRect: bgRect.insetBy(dx: 1, dy: 1),
                            xRadius: cornerRadius, yRadius: cornerRadius)
    glow.lineWidth = max(1, s * 0.006)
    glow.stroke()

    // Inner zones — priority-grid motif (big left + 2 stacked right).
    let innerInset = s * 0.22
    let inner = NSRect(x: innerInset, y: innerInset, width: s - 2*innerInset, height: s - 2*innerInset)
    let gap = max(s * 0.025, 1.5)
    let zoneCorner = s * 0.045

    let leftW = (inner.width - gap) * 0.6
    let rightW = (inner.width - gap) - leftW
    let halfH = (inner.height - gap) / 2

    let mainRect = NSRect(x: inner.minX, y: inner.minY, width: leftW, height: inner.height)
    let topRect  = NSRect(x: inner.minX + leftW + gap, y: inner.midY + gap/2,
                          width: rightW, height: halfH)
    let botRect  = NSRect(x: inner.minX + leftW + gap, y: inner.minY,
                          width: rightW, height: halfH)

    func fillZone(_ rect: NSRect, alpha: CGFloat) {
        NSColor(calibratedWhite: 1.0, alpha: alpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: zoneCorner, yRadius: zoneCorner).fill()
        // Hairline highlight on top edge for a subtle glassy feel.
        NSColor.white.withAlphaComponent(0.30).setStroke()
        let edge = NSBezierPath(roundedRect: rect, xRadius: zoneCorner, yRadius: zoneCorner)
        edge.lineWidth = max(0.5, s * 0.003)
        edge.stroke()
    }
    fillZone(mainRect, alpha: 0.92)
    fillZone(topRect,  alpha: 0.78)
    fillZone(botRect,  alpha: 0.62)

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to encode PNG at \(pixels)px")
    }
    return data
}

for entry in entries {
    let png = drawIcon(pixels: entry.pixels)
    let outURL = iconsetDir.appendingPathComponent(entry.name)
    try png.write(to: outURL)
    print("  wrote \(entry.name)  (\(entry.pixels)px)")
}

print("→ converting iconset to .icns via iconutil")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["--convert", "icns",
                     iconsetDir.path,
                     "--output", icnsURL.path]
try process.run()
process.waitUntilExit()

if process.terminationStatus == 0,
   let attrs = try? FileManager.default.attributesOfItem(atPath: icnsURL.path),
   let size = attrs[.size] as? Int {
    print("✓ AppIcon.icns generated (\(size) bytes)")
} else {
    print("✗ iconutil failed (exit \(process.terminationStatus))")
    exit(1)
}
