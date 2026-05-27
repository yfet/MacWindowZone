import AppKit

/// Applies a zone to a window: resizes, repositions, and records memory.
enum Snapper {

    @discardableResult
    static func snap(window: AXWindow, to zone: Zone, on screen: NSScreen) -> Bool {
        let raw = zone.absoluteRect(in: screen.visibleFrame)
        // Apply half-gap inset on every side so two neighbouring zones leave
        // exactly `Settings.shared.gap` points between their windows.
        let half = Settings.shared.gap / 2.0
        let cocoaRect = raw.insetBy(dx: half, dy: half)
        let axRect = ScreenManager.cocoaToAX(cocoaRect)
        let ok = window.setFrame(axRect)
        if ok {
            WindowMemory.shared.remember(
                bundleID: window.bundleIdentifier,
                windowKey: window.windowKey,
                zoneID: zone.id,
                screenID: ScreenManager.identifier(for: screen),
                frame: axRect
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
