import AppKit
import ApplicationServices

/// Translucent floating window showing the zone layout on a single screen
/// while the user drags a window. The currently hovered zone is highlighted.
///
/// Convenience init only — see the note on `ZoneEditorWindow` for why
/// subclassing NSWindow with a custom designated init crashes AppKit.
final class DragSnapOverlay: NSWindow {

    convenience init(screen: NSScreen) {
        self.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Above almost everything but below screensaver/system alerts.
        level = .statusBar
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = DragSnapView(screen: screen)
        setFrame(screen.frame, display: false)
        alphaValue = 0
    }

    private var canvas: DragSnapView? { contentView as? DragSnapView }

    func update(highlightingZone id: UUID?) {
        canvas?.highlightedZoneID = id
        canvas?.needsDisplay = true
    }

    func fadeIn() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            animator().alphaValue = 1
        }
    }

    func fadeOutAndClose() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }
}

final class DragSnapView: NSView {
    private let screen: NSScreen
    var highlightedZoneID: UUID?

    init(screen: NSScreen) {
        self.screen = screen
        super.init(frame: screen.frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    private func visibleFrameInView() -> NSRect {
        let vf = screen.visibleFrame
        return NSRect(
            x: vf.minX - screen.frame.minX,
            y: vf.minY - screen.frame.minY,
            width: vf.width,
            height: vf.height
        )
    }

    private func zoneRectsInView() -> [(Zone, NSRect)] {
        let id = ScreenManager.identifier(for: screen)
        let layout = ZoneStore.shared.layout(for: id)
        let vf = visibleFrameInView()
        return layout.zones.map { zone in
            let r = NSRect(
                x: vf.minX + zone.fractionalRect.x * vf.width,
                y: vf.minY + zone.fractionalRect.y * vf.height,
                width: zone.fractionalRect.width * vf.width,
                height: zone.fractionalRect.height * vf.height
            )
            return (zone, r)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        for (zone, rect) in zoneRectsInView() {
            let isActive = zone.id == highlightedZoneID
            let fill = (isActive ? NSColor.systemBlue : NSColor.systemTeal).withAlphaComponent(isActive ? 0.45 : 0.18)
            let stroke = (isActive ? NSColor.systemBlue : NSColor.systemTeal).withAlphaComponent(0.95)
            fill.setFill()
            let inset = rect.insetBy(dx: 6, dy: 6)
            NSBezierPath(roundedRect: inset, xRadius: 12, yRadius: 12).fill()
            stroke.setStroke()
            let path = NSBezierPath(roundedRect: inset, xRadius: 12, yRadius: 12)
            path.lineWidth = isActive ? 3 : 1.5
            path.stroke()
        }
    }
}

/// Watches the global mouse stream; while the user drags a window with Shift
/// held, displays zone overlays and snaps the window on release.
final class DragSnapController {
    static let shared = DragSnapController()

    var isEnabled: Bool = true {
        didSet { isEnabled ? start() : stop() }
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?

    // Drag state
    private var draggingWindow: AXWindow?
    private var initialWindowFrameAX: CGRect?
    private var initialMouseAX: CGPoint?
    private var overlaysByScreen: [String: DragSnapOverlay] = [:]
    private var overlayVisible = false

    private init() {}

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .flagsChanged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event: event)
        }
        if globalMonitor == nil {
            Log.line("[MWZ DragSnap] WARNING: global monitor returned nil — system rejected the registration")
        } else {
            Log.line("[MWZ DragSnap] global monitor installed")
        }
        // Local monitor lets us handle events when our own windows are key.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event: event)
            return event
        }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor  { NSEvent.removeMonitor(m); localMonitor = nil }
        hideOverlays()
        resetDragState()
    }

    private func handle(event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            beginCandidate(at: NSEvent.mouseLocation)
        case .leftMouseDragged:
            // If the mouseDown candidate didn't stick (timing/AX glitch),
            // retry on the first drag event so we don't lose the whole gesture.
            if draggingWindow == nil {
                beginCandidate(at: NSEvent.mouseLocation)
            }
            updateDrag(at: NSEvent.mouseLocation, modifiers: event.modifierFlags)
        case .flagsChanged:
            // Modifier toggled mid-drag — refresh overlay state.
            if draggingWindow != nil {
                if Settings.shared.snapModifier.isSatisfied(by: event.modifierFlags) {
                    showOverlays()
                } else {
                    hideOverlays()
                }
            }
        case .leftMouseUp:
            finishDrag(at: NSEvent.mouseLocation, modifiers: event.modifierFlags)
        default:
            break
        }
    }

    private func beginCandidate(at cocoaPoint: NSPoint) {
        resetDragState()
        guard let primary = NSScreen.screens.first else { return }
        let axPoint = CGPoint(x: cocoaPoint.x, y: primary.frame.height - cocoaPoint.y)
        let hit = windowAt(axPoint: axPoint)
        let sysFocus = (hit == nil) ? WindowAX.systemFocusedWindow() : nil
        let wsFocus  = (hit == nil && sysFocus == nil) ? WindowAX.focusedWindow() : nil
        let window = hit ?? sysFocus ?? wsFocus
        guard let window else {
            Log.line("[MWZ DragSnap] mouseDown: no window found at \(axPoint)")
            return
        }
        Log.line("[MWZ DragSnap] mouseDown: candidate=\(window.bundleIdentifier) title=\(window.title) (via \(hit != nil ? "axHit" : sysFocus != nil ? "sysFocus" : "wsFocus"))")
        draggingWindow = window
        initialWindowFrameAX = window.frame
        initialMouseAX = axPoint
    }

    private func updateDrag(at cocoaPoint: NSPoint, modifiers: NSEvent.ModifierFlags) {
        guard draggingWindow != nil else { return }

        let mod = Settings.shared.snapModifier
        // When a modifier is required, the user is being explicit — show the
        // overlay as soon as the modifier is held, even before the window has
        // measurably moved. Without a modifier, gate on actual window movement
        // so we don't flash zones on selection-rect drags etc.
        let modSatisfied = mod.isSatisfied(by: modifiers)
        let movementGate: Bool
        if mod == .none {
            if let window = draggingWindow, let initialFrame = initialWindowFrameAX,
               let currentFrame = window.frame {
                let dx = abs(currentFrame.minX - initialFrame.minX)
                let dy = abs(currentFrame.minY - initialFrame.minY)
                movementGate = (dx + dy) >= 2
            } else {
                movementGate = false
            }
        } else {
            movementGate = true
        }

        if modSatisfied && movementGate {
            if !overlayVisible {
                Log.line("[MWZ DragSnap] showing overlay — mod=\(mod) gate=\(movementGate) flags=\(modifiers.rawValue)")
            }
            showOverlays()
            updateHighlight(cocoaPoint: cocoaPoint)
        } else {
            hideOverlays()
        }
    }

    private func finishDrag(at cocoaPoint: NSPoint, modifiers: NSEvent.ModifierFlags) {
        defer { resetDragState() }
        guard overlayVisible, let window = draggingWindow else {
            hideOverlays()
            return
        }
        hideOverlays()
        guard Settings.shared.snapModifier.isSatisfied(by: modifiers) else { return }
        guard let screen = ScreenManager.screenContaining(point: cocoaPoint) else { return }
        let layout = ZoneStore.shared.layout(for: ScreenManager.identifier(for: screen))
        let vf = screen.visibleFrame
        guard let zone = layout.zones.first(where: { $0.absoluteRect(in: vf).contains(cocoaPoint) }) else { return }
        Snapper.snap(window: window, to: zone, on: screen)
    }

    private func resetDragState() {
        draggingWindow = nil
        initialWindowFrameAX = nil
        initialMouseAX = nil
    }

    // MARK: Overlay management

    private func showOverlays() {
        guard !overlayVisible else { return }
        overlayVisible = true
        for screen in NSScreen.screens {
            let id = ScreenManager.identifier(for: screen)
            let overlay = overlaysByScreen[id] ?? DragSnapOverlay(screen: screen)
            overlaysByScreen[id] = overlay
            overlay.orderFrontRegardless()
            overlay.fadeIn()
        }
    }

    private func hideOverlays() {
        guard overlayVisible else { return }
        overlayVisible = false
        for (_, overlay) in overlaysByScreen { overlay.fadeOutAndClose() }
    }

    private func updateHighlight(cocoaPoint: NSPoint) {
        guard let screen = ScreenManager.screenContaining(point: cocoaPoint) else { return }
        let vf = screen.visibleFrame
        let id = ScreenManager.identifier(for: screen)
        let layout = ZoneStore.shared.layout(for: id)
        let hovered = layout.zones.first(where: { $0.absoluteRect(in: vf).contains(cocoaPoint) })
        for (screenID, overlay) in overlaysByScreen {
            overlay.update(highlightingZone: screenID == id ? hovered?.id : nil)
        }
    }

    // MARK: AX hit testing

    private func windowAt(axPoint: CGPoint) -> AXWindow? {
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(system, Float(axPoint.x), Float(axPoint.y), &element)
        guard result == .success, let hit = element else { return nil }

        // Walk up to the AX window.
        var current: AXUIElement = hit
        for _ in 0..<8 {
            let role = AXWindow.copyString(current, attribute: kAXRoleAttribute as CFString) ?? ""
            if role == (kAXWindowRole as String) {
                var pid: pid_t = 0
                AXUIElementGetPid(current, &pid)
                let runningApp = NSRunningApplication(processIdentifier: pid)
                let title = AXWindow.copyString(current, attribute: kAXTitleAttribute as CFString) ?? ""
                let bundle = runningApp?.bundleIdentifier ?? "unknown.\(pid)"
                return AXWindow(element: current, pid: pid, bundleIdentifier: bundle, title: title)
            }
            var parent: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
               let parentValue = parent {
                current = parentValue as! AXUIElement
            } else { break }
        }
        return nil
    }
}
