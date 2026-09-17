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

    func update(highlightingZones ids: Set<UUID>, showsZones: Bool, edgeTarget: EdgeSnapTarget?) {
        canvas?.highlightedZoneIDs = ids
        canvas?.showsZones = showsZones
        canvas?.edgeTarget = edgeTarget
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
    var highlightedZoneIDs: Set<UUID> = []
    var showsZones = false
    var edgeTarget: EdgeSnapTarget?

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
        let vf = visibleFrameInView()
        let edgeRect = edgeTarget.map { $0.rect(in: vf) }

        if showsZones {
            let pairs = zoneRectsInView()
            let selectedRects = pairs.compactMap { highlightedZoneIDs.contains($0.0.id) ? $0.1 : nil }
            // Two or more zones: draw their bounding box as one snap target
            // (adjacent 2×2 cells become a half, three become fullscreen).
            let union: NSRect? = selectedRects.count >= 2
                ? selectedRects.reduce(NSRect.null) { $0.union($1) }
                : nil

            for (zone, rect) in pairs {
                // Skip cells swallowed by a larger highlight (multi-zone union
                // or an edge-snap preview) so stacked fills don't show seams.
                if let edgeRect, edgeRect.insetBy(dx: -0.5, dy: -0.5).contains(rect) { continue }
                if let union, union.insetBy(dx: -0.5, dy: -0.5).contains(rect) { continue }
                let isActive = edgeRect == nil && union == nil && highlightedZoneIDs.contains(zone.id)
                drawZone(rect: rect, active: isActive)
            }

            if edgeRect == nil, let union, !union.isNull, !union.isEmpty {
                drawZone(rect: union, active: true)
            }
        }

        if let edgeRect, !edgeRect.isNull, !edgeRect.isEmpty {
            drawZone(rect: edgeRect, active: true)
        }
    }

    private func drawZone(rect: NSRect, active: Bool) {
        let fill = (active ? NSColor.systemBlue : NSColor.systemTeal).withAlphaComponent(active ? 0.45 : 0.18)
        let stroke = (active ? NSColor.systemBlue : NSColor.systemTeal).withAlphaComponent(0.95)
        fill.setFill()
        let inset = rect.insetBy(dx: 6, dy: 6)
        NSBezierPath(roundedRect: inset, xRadius: 12, yRadius: 12).fill()
        stroke.setStroke()
        let path = NSBezierPath(roundedRect: inset, xRadius: 12, yRadius: 12)
        path.lineWidth = active ? 3 : 1.5
        path.stroke()
    }
}

/// Watches the global mouse stream.
///
/// * Zone snap: while the configured modifier is held, displays zone overlays
///   and snaps the window on release. Hold Control (Option if Control is the
///   snap modifier) to accumulate zones; the window snaps to their bounding box.
/// * Edge snap: dragging a window to a screen edge/corner (no modifier needed)
///   previews fullscreen / half / quarter and snaps on release.
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
    /// Zones visited while the multi-select modifier is held, in visit order.
    private var selectedZoneIDs: [UUID] = []
    /// Screen the current multi-select set belongs to; crossing screens resets it.
    private var multiSelectScreenID: String?
    /// Aero-style edge/corner target, if the cursor is in the edge buffer.
    private var edgeSnapTarget: EdgeSnapTarget?
    private var edgeSnapScreenID: String?
    /// False until the cursor leaves any edge zone it started in, so clicking
    /// a title bar that's already against the top of the screen doesn't snap.
    private var edgeSnapArmed = false
    private var showsZoneLayout = false

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
            // Modifier toggled mid-drag — refresh overlay / multi-select state.
            if draggingWindow != nil {
                updateDrag(at: NSEvent.mouseLocation, modifiers: event.modifierFlags)
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
        // Don't fire edge-snap if the press already sat in an edge buffer
        // (typical for a window parked under the menu bar).
        if let screen = ScreenManager.screenContaining(point: cocoaPoint) {
            edgeSnapArmed = edgeHit(at: cocoaPoint, on: screen, buffer: Settings.shared.edgeSnapBuffer) == nil
        } else {
            edgeSnapArmed = true
        }
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
            movementGate = dragHasMoved(mouseCocoa: cocoaPoint)
        } else {
            movementGate = true
        }

        let zoneMode = modSatisfied && movementGate
        if !zoneMode {
            selectedZoneIDs = []
            multiSelectScreenID = nil
        }
        let edgeTarget = resolveEdgeTarget(at: cocoaPoint)
        let edgeMode = edgeTarget != nil

        if zoneMode || edgeMode {
            if !overlayVisible {
                Log.line("[MWZ DragSnap] showing overlay — zone=\(zoneMode) edge=\(edgeTarget?.name ?? "none") flags=\(modifiers.rawValue)")
            }
            showsZoneLayout = zoneMode
            showOverlays()
            updateHighlight(cocoaPoint: cocoaPoint, modifiers: modifiers)
        } else {
            hideOverlays()
        }
    }

    private func finishDrag(at cocoaPoint: NSPoint, modifiers: NSEvent.ModifierFlags) {
        let selectedIDs = selectedZoneIDs
        let selectedScreenID = multiSelectScreenID
        let edgeTarget = edgeSnapTarget
        let edgeScreenID = edgeSnapScreenID
        defer { resetDragState() }
        guard overlayVisible, let window = draggingWindow else {
            hideOverlays()
            return
        }
        hideOverlays()

        if let edgeTarget, let screenID = edgeScreenID,
           let screen = ScreenManager.screen(for: screenID) {
            Log.line("[MWZ DragSnap] edge-snap \(edgeTarget.name) on \(screenID)")
            Snapper.snap(window: window, toEdge: edgeTarget, on: screen)
            return
        }

        guard Settings.shared.snapModifier.isSatisfied(by: modifiers) else { return }

        if selectedIDs.count >= 2, let screenID = selectedScreenID,
           let screen = ScreenManager.screen(for: screenID) {
            let layout = ZoneStore.shared.layout(for: screenID)
            let zones = selectedIDs.compactMap { id in layout.zones.first { $0.id == id } }
            if zones.count >= 2 {
                Log.line("[MWZ DragSnap] multi-snap \(zones.count) zones on \(screenID)")
                Snapper.snap(window: window, toZones: zones, on: screen)
                return
            }
        }

        guard let screen = ScreenManager.screenContaining(point: cocoaPoint) else { return }
        let layout = ZoneStore.shared.layout(for: ScreenManager.identifier(for: screen))
        let vf = screen.visibleFrame
        if let id = selectedIDs.first, let zone = layout.zones.first(where: { $0.id == id }) {
            Snapper.snap(window: window, to: zone, on: screen)
            return
        }
        guard let zone = layout.zones.first(where: { $0.absoluteRect(in: vf).contains(cocoaPoint) }) else { return }
        Snapper.snap(window: window, to: zone, on: screen)
    }

    private func resetDragState() {
        draggingWindow = nil
        initialWindowFrameAX = nil
        initialMouseAX = nil
        selectedZoneIDs = []
        multiSelectScreenID = nil
        edgeSnapTarget = nil
        edgeSnapScreenID = nil
        edgeSnapArmed = false
        showsZoneLayout = false
    }

    private func edgeHit(at point: NSPoint, on screen: NSScreen, buffer: CGFloat) -> EdgeSnapTarget? {
        EdgeSnap.target(
            at: point,
            on: screen,
            buffer: buffer,
            portrait: Settings.shared.portraitEdgeBehavior
        )
    }

    /// True once the window or the cursor has actually travelled — used to
    /// ignore clicks and selection-rect drags.
    private func dragHasMoved(mouseCocoa: NSPoint) -> Bool {
        if let window = draggingWindow, let initial = initialWindowFrameAX,
           let current = window.frame {
            if hypot(current.minX - initial.minX, current.minY - initial.minY) >= 4 { return true }
        }
        if let initial = initialMouseAX, let primary = NSScreen.screens.first {
            let ax = CGPoint(x: mouseCocoa.x, y: primary.frame.height - mouseCocoa.y)
            if hypot(ax.x - initial.x, ax.y - initial.y) >= 8 { return true }
        }
        return false
    }

    private func resolveEdgeTarget(at cocoaPoint: NSPoint) -> EdgeSnapTarget? {
        guard Settings.shared.edgeSnapEnabled else {
            edgeSnapTarget = nil
            edgeSnapScreenID = nil
            return nil
        }
        // Don't steal a multi-zone selection the user is painting.
        if selectedZoneIDs.count >= 2 {
            edgeSnapTarget = nil
            edgeSnapScreenID = nil
            return nil
        }
        guard let screen = ScreenManager.screenContaining(point: cocoaPoint) else {
            edgeSnapTarget = nil
            edgeSnapScreenID = nil
            return nil
        }
        let buffer = Settings.shared.edgeSnapBuffer
        var hit = edgeHit(at: cocoaPoint, on: screen, buffer: buffer)
        // Stick to the current target a few points past the buffer so the
        // preview doesn't flicker on the boundary, especially at a display seam.
        if hit == nil, let sticky = edgeSnapTarget,
           edgeHit(at: cocoaPoint, on: screen, buffer: buffer + 12) == sticky {
            hit = sticky
        }
        if !edgeSnapArmed {
            if hit == nil { edgeSnapArmed = true }
            edgeSnapTarget = nil
            edgeSnapScreenID = nil
            return nil
        }
        guard dragHasMoved(mouseCocoa: cocoaPoint) else {
            edgeSnapTarget = nil
            edgeSnapScreenID = nil
            return nil
        }
        edgeSnapTarget = hit
        edgeSnapScreenID = hit != nil ? ScreenManager.identifier(for: screen) : nil
        return hit
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
        selectedZoneIDs = []
        multiSelectScreenID = nil
        for (_, overlay) in overlaysByScreen {
            overlay.update(highlightingZones: [], showsZones: false, edgeTarget: nil)
            overlay.fadeOutAndClose()
        }
        edgeSnapTarget = nil
        edgeSnapScreenID = nil
        showsZoneLayout = false
    }

    private func updateHighlight(cocoaPoint: NSPoint, modifiers: NSEvent.ModifierFlags) {
        guard let screen = ScreenManager.screenContaining(point: cocoaPoint) else { return }
        let vf = screen.visibleFrame
        let id = ScreenManager.identifier(for: screen)
        let layout = ZoneStore.shared.layout(for: id)
        let hovered = layout.zones.first(where: { $0.absoluteRect(in: vf).contains(cocoaPoint) })
        let multi = Settings.shared.snapModifier.isMultiSelectSatisfied(by: modifiers)
        let zoneMode = showsZoneLayout
        let edgeTarget = edgeSnapTarget
        let edgeScreenID = edgeSnapScreenID

        if zoneMode {
            if multi {
                if multiSelectScreenID != id {
                    selectedZoneIDs = []
                    multiSelectScreenID = id
                }
                if let hovered, !selectedZoneIDs.contains(hovered.id) {
                    selectedZoneIDs.append(hovered.id)
                    Log.line("[MWZ DragSnap] multi-select +\(hovered.name) (\(selectedZoneIDs.count) zones)")
                }
            } else if selectedZoneIDs.count >= 2, multiSelectScreenID == id {
                // Keep the accumulated set after Control is released, so a slightly
                // early key-up still snaps to the union. Reset only when the cursor
                // enters a zone that isn't already selected.
                if let hovered, !selectedZoneIDs.contains(hovered.id) {
                    selectedZoneIDs = [hovered.id]
                    multiSelectScreenID = id
                }
            } else {
                selectedZoneIDs = hovered.map { [$0.id] } ?? []
                multiSelectScreenID = hovered != nil ? id : nil
            }
        }

        for (screenID, overlay) in overlaysByScreen {
            let zones: Set<UUID>
            if zoneMode, edgeTarget == nil, screenID == (multiSelectScreenID ?? id) {
                zones = Set(selectedZoneIDs)
            } else {
                zones = []
            }
            overlay.update(
                highlightingZones: zones,
                showsZones: zoneMode,
                edgeTarget: screenID == edgeScreenID ? edgeTarget : nil
            )
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
