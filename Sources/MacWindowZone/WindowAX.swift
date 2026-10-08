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
    /// Sequence:
    /// 1. Temporarily clear `AXEnhancedUserInterface` on the app. Firefox,
    ///    Chromium and several Electron apps ignore `AXSize` while that flag
    ///    is on (they treat it as a VoiceOver probe).
    /// 2. Size → position → size → position. Size-first so macOS will accept
    ///    a frame that doesn't fit the *current* display; the second size
    ///    catches apps that no-op the first call.
    /// 3. Shrink-to-tiny only for cross-screen moves (same-screen shrinks
    ///    reflow terminals/editors).
    /// 4. If the app clamps to a minimum size, re-pin the window so it still
    ///    covers the intended edges of `rect` and stays on-screen.
    @discardableResult
    func setFrame(_ rect: CGRect) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        let wasEnhanced = Self.copyBool(app, attribute: Self.enhancedUIAttribute)
        if wasEnhanced == true {
            Log.line("[MWZ AX] \(bundleIdentifier): disabling AXEnhancedUserInterface for resize")
            Self.setBool(app, attribute: Self.enhancedUIAttribute, value: false)
        }
        defer {
            if wasEnhanced == true {
                Self.setBool(app, attribute: Self.enhancedUIAttribute, value: true)
            }
        }

        let previous = frame
        let needsShrink = Self.movesAcrossScreens(from: previous, to: rect)
        if needsShrink {
            _ = setSize(CGSize(width: 100, height: 100))
        }

        var sizeOK = setSize(rect.size)
        var posOK = setPosition(rect.origin)
        sizeOK = setSize(rect.size) || sizeOK
        posOK = setPosition(rect.origin) || posOK

        var actual = frame
        // Completely ignored the size change — one more try after the first
        // position has landed (Firefox sometimes needs this order).
        if let previous, let current = actual,
           Self.sizesMatch(current.size, previous.size, slop: 2),
           !Self.sizesMatch(current.size, rect.size, slop: 2) {
            Log.line("[MWZ AX] \(bundleIdentifier): size unchanged (\(current.size)), retrying")
            sizeOK = setSize(rect.size) || sizeOK
            posOK = setPosition(rect.origin) || posOK
            actual = frame
        }

        if let current = actual, !Self.sizesMatch(current.size, rect.size, slop: 2) {
            let fitted = Self.fit(actualSize: current.size, into: rect)
            if hypot(fitted.minX - current.minX, fitted.minY - current.minY) > 1 {
                Log.line("[MWZ AX] \(bundleIdentifier): min-size clamp \(current.size) vs \(rect.size); pinning to \(fitted.origin)")
                _ = setPosition(fitted.origin)
            } else {
                Log.line("[MWZ AX] \(bundleIdentifier): size clamped to \(current.size) (wanted \(rect.size))")
            }
        }

        return posOK && sizeOK
    }

    @discardableResult
    private func setPosition(_ point: CGPoint) -> Bool {
        var value = point
        guard let ax = AXValueCreate(.cgPoint, &value) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, ax) == .success
    }

    @discardableResult
    private func setSize(_ size: CGSize) -> Bool {
        var value = size
        guard let ax = AXValueCreate(.cgSize, &value) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, ax) == .success
    }

    /// Place an oversized window so it still covers as much of `target` as
    /// possible and stays inside the destination display's visible frame.
    private static func fit(actualSize: CGSize, into target: CGRect) -> CGRect {
        let screen = screen(forAXRect: target)
        let vfAX: CGRect = {
            guard let screen else { return target }
            return ScreenManager.cocoaToAX(screen.visibleFrame)
        }()
        let slop: CGFloat = 16
        let x = fitAxis(
            targetMin: target.minX, targetMax: target.maxX,
            actual: actualSize.width,
            screenMin: vfAX.minX, screenMax: vfAX.maxX,
            flushMin: abs(target.minX - vfAX.minX) < slop,
            flushMax: abs(target.maxX - vfAX.maxX) < slop
        )
        let y = fitAxis(
            targetMin: target.minY, targetMax: target.maxY,
            actual: actualSize.height,
            screenMin: vfAX.minY, screenMax: vfAX.maxY,
            flushMin: abs(target.minY - vfAX.minY) < slop,
            flushMax: abs(target.maxY - vfAX.maxY) < slop
        )
        return CGRect(origin: CGPoint(x: x, y: y), size: actualSize)
    }

    private static func fitAxis(
        targetMin: CGFloat, targetMax: CGFloat,
        actual: CGFloat,
        screenMin: CGFloat, screenMax: CGFloat,
        flushMin: Bool, flushMax: Bool
    ) -> CGFloat {
        var x: CGFloat
        if actual <= (targetMax - targetMin) + 2 {
            x = targetMin
        } else if flushMin && !flushMax {
            x = targetMin
        } else if flushMax && !flushMin {
            x = targetMax - actual
        } else if flushMin && flushMax {
            x = targetMin
        } else {
            x = (targetMin + targetMax - actual) / 2
        }
        x = min(x, screenMax - actual)
        x = max(x, screenMin)
        return x
    }

    private static func sizesMatch(_ a: CGSize, _ b: CGSize, slop: CGFloat) -> Bool {
        abs(a.width - b.width) <= slop && abs(a.height - b.height) <= slop
    }

    private static let enhancedUIAttribute = "AXEnhancedUserInterface" as CFString

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

    private static func copyBool(_ element: AXUIElement, attribute: CFString) -> Bool? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else { return nil }
        return raw as? Bool
    }

    @discardableResult
    private static func setBool(_ element: AXUIElement, attribute: CFString, value: Bool) -> Bool {
        AXUIElementSetAttributeValue(element, attribute, value as CFBoolean) == .success
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
