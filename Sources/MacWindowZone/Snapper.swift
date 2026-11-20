import AppKit

/// Applies a zone to a window: resizes, repositions, and records memory.
enum Snapper {

    @discardableResult
    static func snap(window: AXWindow, to zone: Zone, on screen: NSScreen) -> Bool {
        snap(
            window: window,
            toRect: zone.absoluteRect(in: screen.visibleFrame),
            on: screen,
            zoneID: zone.id,
            zoneIDs: nil
        )
    }

    /// Snap to an Aero-style edge/corner target (fullscreen, half, quarter).
    @discardableResult
    static func snap(window: AXWindow, toEdge target: EdgeSnapTarget, on screen: NSScreen) -> Bool {
        snap(
            window: window,
            toRect: target.rect(in: screen.visibleFrame),
            on: screen,
            zoneID: nil,
            zoneIDs: nil
        )
    }

    /// Snap to the bounding box of several zones (FancyZones-style multi-select).
    @discardableResult
    static func snap(window: AXWindow, toZones zones: [Zone], on screen: NSScreen) -> Bool {
        guard let first = zones.first else { return false }
        if zones.count == 1 {
            return snap(window: window, to: first, on: screen)
        }
        guard let union = Zone.boundingRect(of: zones, in: screen.visibleFrame) else { return false }
        return snap(
            window: window,
            toRect: union,
            on: screen,
            zoneID: nil,
            zoneIDs: zones.map(\.id)
        )
    }

    /// Window frame for a zone rect, leaving the same `gap` everywhere:
    /// half a gap on sides shared with a neighbour (the neighbour adds the
    /// other half), a full gap on sides that touch the visible frame.
    /// `rect` and `vf` must be in the same coordinate space.
    static func gappedRect(_ rect: CGRect, in vf: CGRect, gap: CGFloat) -> CGRect {
        let half = gap / 2
        let tol: CGFloat = 1
        let l = abs(rect.minX - vf.minX) < tol ? gap : half
        let r = abs(rect.maxX - vf.maxX) < tol ? gap : half
        let b = abs(rect.minY - vf.minY) < tol ? gap : half
        let t = abs(rect.maxY - vf.maxY) < tol ? gap : half
        let out = CGRect(
            x: rect.minX + l,
            y: rect.minY + b,
            width: rect.width - l - r,
            height: rect.height - b - t
        )
        return (out.width > 0 && out.height > 0) ? out : rect.insetBy(dx: half, dy: half)
    }

    @discardableResult
    private static func snap(
        window: AXWindow,
        toRect raw: CGRect,
        on screen: NSScreen,
        zoneID: UUID?,
        zoneIDs: [UUID]?
    ) -> Bool {
        let cocoaRect = gappedRect(raw, in: screen.visibleFrame, gap: Settings.shared.gap)
        let axRect = ScreenManager.cocoaToAX(cocoaRect)
        let ok = window.setFrame(axRect)
        if ok {
            WindowMemory.shared.remember(
                bundleID: window.bundleIdentifier,
                windowKey: window.windowKey,
                zoneID: zoneID,
                zoneIDs: zoneIDs,
                screenID: ScreenManager.identifier(for: screen),
                frame: window.frame ?? axRect
            )
        }
        return ok
    }

    /// Snap the focused window to the Nth zone (1-indexed) on the screen
    /// currently containing the focused window.
    @discardableResult
    static func snapFocused(toZoneIndex index: Int) -> Bool {
        guard let win = WindowAX.focusedWindow(),
              let frame = win.frame else { return false }
        // The window's frame is in AX coords; find the matching NSScreen.
        guard let primary = NSScreen.screens.first else { return false }
        let cocoaPoint = NSPoint(x: frame.midX, y: primary.frame.height - frame.midY)
        let screen = ScreenManager.screenContaining(point: cocoaPoint) ?? primary
        let layout = ZoneStore.shared.layout(for: ScreenManager.identifier(for: screen))
        guard index >= 1, index <= layout.zones.count else { return false }
        return snap(window: win, to: layout.zones[index - 1], on: screen)
    }
}
