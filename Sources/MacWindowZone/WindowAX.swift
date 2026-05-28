import AppKit
import ApplicationServices

/// Lightweight wrapper around the Accessibility API for window manipulation.
struct AXWindow {
    let element: AXUIElement
    let pid: pid_t
    let bundleIdentifier: String
    let title: String

    var frame: CGRect? {
        guard let position = AXWindow.copyPoint(element, attribute: kAXPositionAttribute as CFString),
              let size     = AXWindow.copySize(element,  attribute: kAXSizeAttribute     as CFString) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    /// Set a frame in *AX/Quartz* coordinates (origin top-left of primary display).
    ///
    /// We shrink-then-grow ONLY for cross-screen moves. On the same screen the
    /// window already fits, and the shrink causes content-wrapping apps
    /// (terminals, editors) to reflow at 100px and then sometimes fail to
    /// reflow back to full width on grow.
    @discardableResult
    func setFrame(_ rect: CGRect) -> Bool {
        var position = rect.origin
        var size = rect.size
        guard let posValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return false }

        let needsShrink = Self.movesAcrossScreens(from: frame, to: rect)

        if needsShrink {
            var tinySize = CGSize(width: 100, height: 100)
            if let tinyValue = AXValueCreate(.cgSize, &tinySize) {
                AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, tinyValue)
            }
        }

        let posResult = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue)
        let sizeResult = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        // Re-apply position once — some apps clamp on resize.
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue)
        return posResult == .success && sizeResult == .success
    }

    /// AX → screen mapping: returns the NSScreen containing the center of
    /// `axRect`. Returns nil if no screen contains it.
    private static func screen(forAXRect axRect: CGRect) -> NSScreen? {
        guard let primary = NSScreen.screens.first else { return nil }
        let cocoaCenter = NSPoint(
            x: axRect.midX,
            y: primary.frame.height - axRect.midY
        )
        return NSScreen.screens.first { $0.frame.contains(cocoaCenter) }
    }

    private static func movesAcrossScreens(from current: CGRect?, to target: CGRect) -> Bool {
        guard let current else { return false }
        let cur = screen(forAXRect: current)
        let tgt = screen(forAXRect: target)
        guard let cur, let tgt else { return false }
        return cur !== tgt
    }

    var isMinimized: Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &raw) == .success,
              let value = raw as? Bool else { return false }
        return value
    }

    var subrole: String? {
        AXWindow.copyString(element, attribute: kAXSubroleAttribute as CFString)
    }

    /// Only standard top-level windows should be auto-restored. Dialogs,
    /// sheets, popovers and floating panels share the `AXWindow` role but
    /// carry a different subrole; moving them on open is disruptive (e.g.
    /// IDE autocomplete/quick-open popups jumping to a remembered zone).
    var isStandardWindow: Bool {
        subrole == (kAXStandardWindowSubrole as String)
    }

    /// A normalised "window key" used as part of the memory store key.
    /// We hash the title prefix so two browser tabs share a slot.
    var windowKey: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "untitled" }
        // Use the first 40 chars to keep stability while staying compact.
        return String(trimmed.prefix(60))
    }

    // MARK: - Helpers

    private static func copyPoint(_ element: AXUIElement, attribute: CFString) -> CGPoint? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else { return nil }
        guard let value = raw, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        if AXValueGetValue(value as! AXValue, .cgPoint, &point) { return point }
        return nil
    }

    private static func copySize(_ element: AXUIElement, attribute: CFString) -> CGSize? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else { return nil }
        guard let value = raw, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        if AXValueGetValue(value as! AXValue, .cgSize, &size) { return size }
        return nil
    }

    static func copyString(_ element: AXUIElement, attribute: CFString) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else { return nil }
        return raw as? String
    }
}

enum WindowAX {

    static func ensureAccessibilityTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue()
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Returns the focused window of the frontmost app, if any.
    static func focusedWindow() -> AXWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return focusedWindow(for: app)
    }

    static func focusedWindow(for runningApp: NSRunningApplication) -> AXWindow? {
        let appElement = AXUIElementCreateApplication(runningApp.processIdentifier)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &raw) == .success,
              let value = raw else { return nil }
        let element = value as! AXUIElement
        let title = AXWindow.copyString(element, attribute: kAXTitleAttribute as CFString) ?? ""
        return AXWindow(
            element: element,
            pid: runningApp.processIdentifier,
            bundleIdentifier: runningApp.bundleIdentifier ?? "unknown.\(runningApp.processIdentifier)",
            title: title
        )
    }

    /// System-wide focused window (uses AX, more reliable than NSWorkspace
    /// in the middle of a mouseDown that's about to shift focus).
    static func systemFocusedWindow() -> AXWindow? {
        let system = AXUIElementCreateSystemWide()
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedWindowAttribute as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let app = NSRunningApplication(processIdentifier: pid)
        let title = AXWindow.copyString(element, attribute: kAXTitleAttribute as CFString) ?? ""
        let bundle = app?.bundleIdentifier ?? "unknown.\(pid)"
        return AXWindow(element: element, pid: pid, bundleIdentifier: bundle, title: title)
    }

    static func windows(for runningApp: NSRunningApplication) -> [AXWindow] {
        let appElement = AXUIElementCreateApplication(runningApp.processIdentifier)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &raw) == .success,
              let array = raw as? [AXUIElement] else { return [] }
        let bundle = runningApp.bundleIdentifier ?? "unknown.\(runningApp.processIdentifier)"
        return array.map { element in
            let title = AXWindow.copyString(element, attribute: kAXTitleAttribute as CFString) ?? ""
            return AXWindow(element: element, pid: runningApp.processIdentifier, bundleIdentifier: bundle, title: title)
        }
    }
}
