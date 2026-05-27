import AppKit
import CoreGraphics

enum ScreenManager {
    /// A reasonably stable identifier across launches. Uses the display's
    /// CGDirectDisplayID converted to its persistent UUID when available.
    static func identifier(for screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let displayID = CGDirectDisplayID(number.uint32Value)
            if let uuidRef = CGDisplayCreateUUIDFromDisplayID(displayID) {
                let uuid = uuidRef.takeRetainedValue()
                return CFUUIDCreateString(nil, uuid) as String
            }
            return "display-\(displayID)"
        }
        return screen.localizedName
    }

    static func screen(for id: String) -> NSScreen? {
        NSScreen.screens.first { identifier(for: $0) == id }
    }

    /// Visible frame in *Cocoa* coordinates (origin bottom-left, includes menu/dock exclusions).
    static func visibleFrame(for screen: NSScreen) -> CGRect {
        screen.visibleFrame
    }

    /// Convert a Cocoa rect to AX/Quartz coordinates (origin top-left, y inverted
    /// relative to the *primary* screen, which is `NSScreen.screens.first`).
    static func cocoaToAX(_ rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        let primaryHeight = primary.frame.height
        return CGRect(
            x: rect.minX,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func screenContaining(point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }
}
