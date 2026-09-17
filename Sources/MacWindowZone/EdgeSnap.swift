import AppKit

/// Aero-style snap target produced by dragging a window to a screen edge or corner.
enum EdgeSnapTarget: Equatable {
    case full
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight

    var name: String {
        switch self {
        case .full:        return "Full"
        case .leftHalf:    return "Left half"
        case .rightHalf:   return "Right half"
        case .topHalf:     return "Top half"
        case .bottomHalf:  return "Bottom half"
        case .topLeft:     return "Top left"
        case .topRight:    return "Top right"
        case .bottomLeft:  return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }

    var fractionalRect: FractionalRect {
        switch self {
        case .full:        return .full
        case .leftHalf:    return .init(x: 0,   y: 0,   width: 0.5, height: 1)
        case .rightHalf:   return .init(x: 0.5, y: 0,   width: 0.5, height: 1)
        case .topHalf:     return .init(x: 0,   y: 0.5, width: 1,   height: 0.5)
        case .bottomHalf:  return .init(x: 0,   y: 0,   width: 1,   height: 0.5)
        case .topLeft:     return .init(x: 0,   y: 0.5, width: 0.5, height: 0.5)
        case .topRight:    return .init(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .bottomLeft:  return .init(x: 0,   y: 0,   width: 0.5, height: 0.5)
        case .bottomRight: return .init(x: 0.5, y: 0,   width: 0.5, height: 0.5)
        }
    }

    func rect(in frame: CGRect) -> CGRect {
        let f = fractionalRect
        return CGRect(
            x: frame.minX + f.x * frame.width,
            y: frame.minY + f.y * frame.height,
            width: f.width * frame.width,
            height: f.height * frame.height
        )
    }
}

enum EdgeSnap {
    /// Portrait if the display is taller than it is wide (rotation already
    /// reflected in `NSScreen.frame`).
    static func isPortrait(_ screen: NSScreen) -> Bool {
        screen.frame.height > screen.frame.width
    }

    /// Hit-test `point` (Cocoa) against `screen.frame`.
    ///
    /// Landscape: top → fullscreen, left/right → halves, corners → quarters.
    /// Portrait follows `portrait` (top-fills / all-edges-split / landscape).
    ///
    /// `buffer` is the interior margin (points) that counts as "on the edge".
    /// macOS does not clamp the cursor at a shared display seam, so a wider
    /// buffer is what makes inner-edge snaps hittable.
    static func target(
        at point: NSPoint,
        on screen: NSScreen,
        buffer: CGFloat,
        portrait: PortraitEdgeBehavior
    ) -> EdgeSnapTarget? {
        let frame = screen.frame
        // Inclusive on maxX/maxY — CGRect.contains is max-exclusive, which
        // drops the actual outer pixel the cursor rests on.
        guard point.x >= frame.minX, point.x <= frame.maxX,
              point.y >= frame.minY, point.y <= frame.maxY else { return nil }

        let edge = max(buffer, 1)
        // Corners get a slightly deeper hit box so quarters stay easy to grab
        // even with a thin edge buffer.
        let corner = max(edge, 48)

        let nearLeft   = point.x <= frame.minX + edge
        let nearRight  = point.x >= frame.maxX - edge
        let nearBottom = point.y <= frame.minY + edge
        let nearTop    = point.y >= frame.maxY - edge

        let inTopLeft     = point.x <= frame.minX + corner && point.y >= frame.maxY - corner
        let inTopRight    = point.x >= frame.maxX - corner && point.y >= frame.maxY - corner
        let inBottomLeft  = point.x <= frame.minX + corner && point.y <= frame.minY + corner
        let inBottomRight = point.x >= frame.maxX - corner && point.y <= frame.minY + corner

        if inTopLeft     { return .topLeft }
        if inTopRight    { return .topRight }
        if inBottomLeft  { return .bottomLeft }
        if inBottomRight { return .bottomRight }

        if isPortrait(screen) {
            switch portrait {
            case .topFillsSidesSplit:
                if nearTop { return .full }
                if nearBottom { return .bottomHalf }
                if nearLeft || nearRight {
                    return point.y >= frame.midY ? .topHalf : .bottomHalf
                }
                return nil
            case .allEdgesSplit:
                guard nearLeft || nearRight || nearTop || nearBottom else { return nil }
                return point.y >= frame.midY ? .topHalf : .bottomHalf
            case .landscape:
                break
            }
        }

        if nearTop   { return .full }
        if nearLeft  { return .leftHalf }
        if nearRight { return .rightHalf }
        return nil
    }
}
