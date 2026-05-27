import Foundation
import AppKit

/// Predefined layouts that pre-populate a screen with zones. The user can
/// still edit/add/remove zones in the editor afterwards.
enum ZoneTemplate: Hashable {
    case empty
    case focus
    case columns(Int)
    case rows(Int)
    case grid(cols: Int, rows: Int)
    case priorityGrid
    case leftRight       // two halves (default)

    var displayName: String {
        switch self {
        case .empty:               return "No Layout"
        case .focus:               return "Focus"
        case .columns(let n):      return "\(n) Columns"
        case .rows(let n):         return "\(n) Rows"
        case .grid(let c, let r):  return "\(c)×\(r) Grid"
        case .priorityGrid:        return "Priority Grid"
        case .leftRight:           return "Left / Right Halves"
        }
    }

    /// All templates surfaced in the picker, in display order.
    static let pickerOrder: [ZoneTemplate] = [
        .empty,
        .focus,
        .leftRight,
        .columns(3),
        .rows(2),
        .rows(3),
        .grid(cols: 2, rows: 2),
        .grid(cols: 3, rows: 3),
        .priorityGrid
    ]

    /// Generate the (non-overlapping) fractional zones for this template.
    func makeZones() -> [Zone] {
        switch self {
        case .empty:
            return []

        case .focus:
            return [Zone(name: "Focus", fractionalRect: .init(x: 0.18, y: 0.12, width: 0.64, height: 0.76))]

        case .leftRight:
            return [
                Zone(name: "Left",  fractionalRect: .init(x: 0,   y: 0, width: 0.5, height: 1)),
                Zone(name: "Right", fractionalRect: .init(x: 0.5, y: 0, width: 0.5, height: 1))
            ]

        case .columns(let n):
            let w = 1.0 / CGFloat(n)
            return (0..<n).map { i in
                Zone(name: "Col \(i + 1)", fractionalRect: .init(x: CGFloat(i) * w, y: 0, width: w, height: 1))
            }

        case .rows(let n):
            let h = 1.0 / CGFloat(n)
            return (0..<n).map { i in
                // y=0 is bottom in Cocoa, but our fractional rect is computed
                // against visibleFrame so we keep it the same; the editor view
                // already uses Cocoa coordinates. Row 1 should be at the top.
                let topIndex = n - 1 - i
                return Zone(
                    name: "Row \(i + 1)",
                    fractionalRect: .init(x: 0, y: CGFloat(topIndex) * h, width: 1, height: h)
                )
            }

        case .grid(let cols, let rows):
            let w = 1.0 / CGFloat(cols)
            let h = 1.0 / CGFloat(rows)
            var result: [Zone] = []
            for r in 0..<rows {
                for c in 0..<cols {
                    let topRowIndex = rows - 1 - r
                    result.append(Zone(
                        name: "Z\(r * cols + c + 1)",
                        fractionalRect: .init(
                            x: CGFloat(c) * w,
                            y: CGFloat(topRowIndex) * h,
                            width: w,
                            height: h
                        )
                    ))
                }
            }
            return result

        case .priorityGrid:
            return [
                Zone(name: "Main",  fractionalRect: .init(x: 0,   y: 0,   width: 0.6, height: 1)),
                Zone(name: "Top",   fractionalRect: .init(x: 0.6, y: 0.5, width: 0.4, height: 0.5)),
                Zone(name: "Bot",   fractionalRect: .init(x: 0.6, y: 0,   width: 0.4, height: 0.5))
            ]
        }
    }

    /// Render a small bitmap preview of the layout for the picker tile.
    func thumbnail(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let bg = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 8, yRadius: 8)
        NSColor(calibratedWhite: 1, alpha: 0.06).setFill()
        bg.fill()
        NSColor(calibratedWhite: 1, alpha: 0.18).setStroke()
        bg.lineWidth = 1
        bg.stroke()

        // Render each zone proportional to the thumbnail size.
        let zones = makeZones()
        for zone in zones {
            let r = NSRect(
                x: 4 + zone.fractionalRect.x * (size.width - 8),
                y: 4 + zone.fractionalRect.y * (size.height - 8),
                width: zone.fractionalRect.width * (size.width - 8),
                height: zone.fractionalRect.height * (size.height - 8)
            ).insetBy(dx: 2, dy: 2)
            NSColor.systemBlue.withAlphaComponent(0.35).setFill()
            let p = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
            p.fill()
            NSColor.systemBlue.withAlphaComponent(0.85).setStroke()
            p.lineWidth = 1.2
            p.stroke()
        }

        if zones.isEmpty {
            let text = NSAttributedString(
                string: "—",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 24, weight: .light),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.3)
                ]
            )
            let s = text.size()
            text.draw(at: NSPoint(x: (size.width - s.width)/2, y: (size.height - s.height)/2))
        }
        return image
    }
}
