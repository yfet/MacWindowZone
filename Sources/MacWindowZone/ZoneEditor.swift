import AppKit

/// Full-screen translucent overlay that lets the user draw / edit zones on a screen.
///
/// IMPORTANT: this is a *convenience* initializer. NSWindow's designated
/// `initWithContentRect:styleMask:backing:defer:screen:` calls the 4-arg
/// designated init on `self`. If we declared our own designated init we'd
/// silently trap (SIGTRAP) inside AppKit, because Swift would synthesise a
/// failing override for the 4-arg init that the runtime can't satisfy.
final class ZoneEditorWindow: NSWindow {

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
        level = .floating
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let screenID = ScreenManager.identifier(for: screen)
        let layout = ZoneStore.shared.layout(for: screenID)
        contentView = ZoneEditorView(screen: screen, layout: layout)
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class ZoneEditorController: NSObject {
    static let shared = ZoneEditorController()
    private var windows: [ZoneEditorWindow] = []
    private var pickerWindow: TemplatePickerWindow?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private(set) var isActive = false

    func toggle() {
        if isActive { close() } else { open() }
    }

    /// Public entry: show the template picker first, then enter the editor.
    func open() {
        guard !isActive, pickerWindow == nil else { return }
        let initial = NSScreen.main ?? NSScreen.screens.first
        guard let initial else { return }
        let picker = TemplatePickerWindow(
            initialScreen: initial,
            onApply: { template, screen in
                // Apply the chosen template to the SELECTED screen only.
                let id = ScreenManager.identifier(for: screen)
                var layout = ZoneStore.shared.layout(for: id)
                layout.zones = template.makeZones()
                ZoneStore.shared.setLayout(layout)
            },
            onFinish: { [weak self] openEditor in
                guard let self else { return }
                self.pickerWindow = nil
                if openEditor { self.openEditorDirectly() }
            }
        )
        pickerWindow = picker
        picker.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Skip the picker and go straight into the editor (used by menu actions
    /// that already imply "keep current zones").
    func openEditorDirectly() {
        guard !isActive else { return }

        // Stay in .accessory so the status bar item is unaffected. The editor
        // windows override `canBecomeKey`, so they can still take keyboard
        // input once clicked, and we install event monitors as a safety net.
        windows = NSScreen.screens.map { ZoneEditorWindow(screen: $0) }
        windows.forEach { $0.orderFrontRegardless() }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return }
            DispatchQueue.main.async { self.handleKey(event) }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }

        isActive = true
        NotificationCenter.default.post(name: .zoneEditorStateChanged, object: nil)
    }

    func close() {
        guard isActive else { return }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
        if let m = localKeyMonitor  { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        isActive = false
        NotificationCenter.default.post(name: .zoneEditorStateChanged, object: nil)
    }

    /// Returns true if the key was consumed.
    @discardableResult
    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // Escape
            close()
            return true
        default:
            return false
        }
    }
}

extension Notification.Name {
    static let zoneEditorStateChanged = Notification.Name("MWZ.zoneEditorStateChanged")
}

/// Where on a zone the cursor is — drives both cursor shape and drag semantics.
private enum ZoneHit {
    case outside
    case body
    case edgeLeft, edgeRight, edgeTop, edgeBottom
    case cornerTL, cornerTR, cornerBL, cornerBR

    var cursor: NSCursor {
        switch self {
        case .outside:                       return .crosshair
        case .body:                          return .openHand
        case .edgeLeft, .edgeRight:          return .resizeLeftRight
        case .edgeTop, .edgeBottom:          return .resizeUpDown
        case .cornerTL, .cornerBR:           return ZoneEditorView.diagonalCursor
        case .cornerTR, .cornerBL:           return ZoneEditorView.antiDiagonalCursor
        }
    }
}

/// The drawing surface inside the editor window.
final class ZoneEditorView: NSView {
    private let screen: NSScreen
    private let screenID: String
    private var layout: ScreenLayout
    private static let edgeBand: CGFloat = 12

    private struct ResizeSides: OptionSet {
        let rawValue: Int
        static let left   = ResizeSides(rawValue: 1 << 0)
        static let right  = ResizeSides(rawValue: 1 << 1)
        static let bottom = ResizeSides(rawValue: 1 << 2)
        static let top    = ResizeSides(rawValue: 1 << 3)
    }

    private enum DragKind {
        case create(start: NSPoint, current: NSPoint)
        case move(zoneID: UUID, offset: NSSize, originalSize: NSSize)
        /// Resize one or more sides of a zone, like a window's resize handles.
        /// `originalLayout` is a snapshot taken at mouseDown — each frame of
        /// the drag is computed from this baseline so position matching on
        /// shared edges keeps working across frames.
        case resize(zoneID: UUID, originalLayout: ScreenLayout, originalRect: NSRect, sides: ResizeSides)
    }
    private var drag: DragKind?
    private var selectedZoneID: UUID?

    init(screen: NSScreen, layout: ScreenLayout) {
        self.screen = screen
        self.screenID = ScreenManager.identifier(for: screen)
        self.layout = layout
        super.init(frame: screen.frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.18).cgColor
    }

    // Diagonal cursors don't exist as built-ins. Build them programmatically.
    static let diagonalCursor: NSCursor = makeDiagonalCursor(antiDiagonal: false)
    static let antiDiagonalCursor: NSCursor = makeDiagonalCursor(antiDiagonal: true)

    private static func makeDiagonalCursor(antiDiagonal: Bool) -> NSCursor {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setStroke()
        NSColor.black.setFill()
        let line = NSBezierPath()
        line.lineWidth = 2
        if antiDiagonal {
            line.move(to: NSPoint(x: 4, y: 4))
            line.line(to: NSPoint(x: 20, y: 20))
        } else {
            line.move(to: NSPoint(x: 4, y: 20))
            line.line(to: NSPoint(x: 20, y: 4))
        }
        line.stroke()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }

    /// Rect in view-local coordinates of the on-screen "Done" pill.
    private func doneButtonRect() -> NSRect {
        let vf = visibleFrameInView()
        let size = NSSize(width: 120, height: 36)
        return NSRect(
            x: vf.maxX - size.width - 24,
            y: vf.maxY - size.height - 24,
            width: size.width,
            height: size.height
        )
    }

    private func hit(point p: NSPoint, in rect: NSRect) -> ZoneHit {
        guard rect.contains(p) else { return .outside }
        let band = Self.edgeBand
        let nearL = p.x - rect.minX < band
        let nearR = rect.maxX - p.x < band
        let nearB = p.y - rect.minY < band
        let nearT = rect.maxY - p.y < band
        switch (nearT, nearB, nearL, nearR) {
        case (true, _, true, _):  return .cornerTL
        case (true, _, _, true):  return .cornerTR
        case (_, true, true, _):  return .cornerBL
        case (_, true, _, true):  return .cornerBR
        case (true, _, _, _):     return .edgeTop
        case (_, true, _, _):     return .edgeBottom
        case (_, _, true, _):     return .edgeLeft
        case (_, _, _, true):     return .edgeRight
        default:                  return .body
        }
    }

    /// Map a hit on an edge/corner to the set of zone sides that follow the cursor.
    /// Top/Bottom use Cocoa coordinates: `top` means the side at `rect.maxY`.
    private func sidesForResize(hit: ZoneHit) -> ResizeSides? {
        switch hit {
        case .edgeLeft:   return .left
        case .edgeRight:  return .right
        case .edgeTop:    return .top
        case .edgeBottom: return .bottom
        case .cornerTL:   return [.top, .left]
        case .cornerTR:   return [.top, .right]
        case .cornerBL:   return [.bottom, .left]
        case .cornerBR:   return [.bottom, .right]
        default:          return nil
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    // Without this the very first click on the editor only activates the
    // borderless window — the view doesn't receive the mouseDown, and the
    // user has to click twice to start a resize/move.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            ZoneEditorController.shared.close()
        case 51, 117: // Delete / Forward Delete
            if let id = selectedZoneID {
                deleteZoneAndAbsorb(id: id)
                selectedZoneID = nil
                needsDisplay = true
            }
        case 15 where event.modifierFlags.contains(.command): // ⌘R reset
            ZoneStore.shared.resetScreen(screenID)
            layout = ZoneStore.shared.layout(for: screenID)
            needsDisplay = true
        default:
            super.keyDown(with: event)
        }
    }

    // Convert screen-space NSScreen coordinates to view-local coordinates.
    private func viewPoint(from event: NSEvent) -> NSPoint {
        let p = event.locationInWindow
        return convert(p, from: nil)
    }

    private func visibleFrameInView() -> NSRect {
        // visibleFrame is in screen coordinates; bring it into view space.
        let vf = screen.visibleFrame
        let local = NSRect(
            x: vf.minX - screen.frame.minX,
            y: vf.minY - screen.frame.minY,
            width: vf.width,
            height: vf.height
        )
        return local
    }

    private func zoneRectsInView() -> [(Zone, NSRect)] {
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

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = viewPoint(from: event)

        // Done button has highest priority.
        if doneButtonRect().contains(p) {
            ZoneEditorController.shared.close()
            return
        }

        // Modifier-based zone splits.
        // Shift+click on a zone → split vertically (cut creates left/right)
        // Control+click on a zone → split horizontally (cut creates top/bottom)
        // Split happens AT THE CLICK POSITION so the user can choose where.
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.shift) || mods.contains(.control) {
            for (zone, rect) in zoneRectsInView().reversed() where rect.contains(p) {
                splitZone(zone, in: rect, at: p, vertical: mods.contains(.shift))
                return
            }
            return
        }

        let zones = zoneRectsInView()
        for (zone, rect) in zones.reversed() {
            let h = hit(point: p, in: rect)
            switch h {
            case .outside:
                continue
            case .body:
                drag = .move(
                    zoneID: zone.id,
                    offset: NSSize(width: p.x - rect.minX, height: p.y - rect.minY),
                    originalSize: rect.size
                )
                selectedZoneID = zone.id
                needsDisplay = true
                return
            case .edgeLeft, .edgeRight, .edgeTop, .edgeBottom,
                 .cornerTL, .cornerTR, .cornerBL, .cornerBR:
                if let sides = sidesForResize(hit: h) {
                    drag = .resize(
                        zoneID: zone.id,
                        originalLayout: layout,
                        originalRect: rect,
                        sides: sides
                    )
                    selectedZoneID = zone.id
                    needsDisplay = true
                    return
                }
            }
        }
        selectedZoneID = nil
        drag = .create(start: p, current: p)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = viewPoint(from: event)
        switch drag {
        case .create(let start, _):
            drag = .create(start: start, current: p)
        case .move(let id, let offset, let originalSize):
            updateZone(id: id) { zone, vf in
                // Clamp the new origin so the rect stays inside vf.
                let minX = vf.minX
                let maxX = vf.maxX - originalSize.width
                let minY = vf.minY
                let maxY = vf.maxY - originalSize.height
                let nx = (maxX > minX) ? max(minX, min(p.x - offset.width,  maxX)) : minX
                let ny = (maxY > minY) ? max(minY, min(p.y - offset.height, maxY)) : minY
                let rect = NSRect(origin: NSPoint(x: nx, y: ny), size: originalSize)
                zone.fractionalRect = FractionalRect.from(absolute: rect, in: vf)
            }
        case .resize(_, let originalLayout, let originalRect, let sides):
            applySharedResize(originalLayout: originalLayout, originalRect: originalRect, sides: sides, cursor: p)
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; needsDisplay = true }
        switch drag {
        case .create(let start, let current):
            let raw = NSRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(current.x - start.x),
                height: abs(current.y - start.y)
            )
            guard raw.width > 40, raw.height > 40 else { return }
            let vf = visibleFrameInView()
            let clipped = raw.intersection(vf)
            guard !clipped.isNull, !clipped.isEmpty else { return }
            let frac = FractionalRect.from(absolute: clipped, in: vf)
            let zone = Zone(name: "Zone \(layout.zones.count + 1)", fractionalRect: frac)
            ZoneStore.shared.upsertZone(zone, screenID: screenID)
            layout = ZoneStore.shared.layout(for: screenID)
            selectedZoneID = zone.id
        case .move, .resize:
            layout = ZoneStore.shared.layout(for: screenID)
        case .none:
            break
        }
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(for: viewPoint(from: event))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(for: viewPoint(from: event))
    }

    private func updateCursor(for p: NSPoint) {
        if doneButtonRect().contains(p) { NSCursor.pointingHand.set(); return }
        for (_, rect) in zoneRectsInView().reversed() {
            let h = hit(point: p, in: rect)
            if h != .outside { h.cursor.set(); return }
        }
        NSCursor.crosshair.set()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseMoved, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    /// FancyZones-style "shared edge" resize: every zone whose edge is colinear
    /// with the dragged edge moves with it. This keeps the layout tiled with
    /// no gaps or overlaps. Works both axes if the user grabbed a corner.
    ///
    /// Important: we always compute the new layout from `originalLayout`
    /// (snapshot at mouseDown), never from `layout` (current). Otherwise
    /// after the first frame the zones no longer match `oldX/oldY` and
    /// subsequent drag frames become no-ops.
    private func applySharedResize(
        originalLayout: ScreenLayout,
        originalRect: NSRect,
        sides: ResizeSides,
        cursor p: NSPoint
    ) {
        let vf = visibleFrameInView()
        let tol: CGFloat = 1.5
        let minSize: CGFloat = 60
        var newLayout = originalLayout

        // --- X axis ---
        if sides.contains(.left) || sides.contains(.right) {
            let oldX: CGFloat = sides.contains(.left) ? originalRect.minX : originalRect.maxX
            var targetX = max(vf.minX, min(p.x, vf.maxX))

            var minAllowed = vf.minX
            var maxAllowed = vf.maxX
            for zone in originalLayout.zones {
                let r = zone.absoluteRect(in: vf)
                if abs(r.minX - oldX) < tol { maxAllowed = min(maxAllowed, r.maxX - minSize) }
                if abs(r.maxX - oldX) < tol { minAllowed = max(minAllowed, r.minX + minSize) }
            }
            targetX = max(minAllowed, min(targetX, maxAllowed))

            for i in 0..<newLayout.zones.count {
                let originalR = originalLayout.zones[i].absoluteRect(in: vf)
                var r = originalR
                var changed = false
                if abs(originalR.minX - oldX) < tol {
                    r.size.width = originalR.maxX - targetX
                    r.origin.x = targetX
                    changed = true
                }
                if abs(originalR.maxX - oldX) < tol {
                    r.size.width = targetX - originalR.minX
                    changed = true
                }
                if changed {
                    newLayout.zones[i].fractionalRect = FractionalRect.from(absolute: r, in: vf)
                }
            }
        }

        // --- Y axis ---
        if sides.contains(.top) || sides.contains(.bottom) {
            let oldY: CGFloat = sides.contains(.top) ? originalRect.maxY : originalRect.minY
            var targetY = max(vf.minY, min(p.y, vf.maxY))

            var minAllowed = vf.minY
            var maxAllowed = vf.maxY
            for zone in originalLayout.zones {
                let r = zone.absoluteRect(in: vf)
                if abs(r.minY - oldY) < tol { maxAllowed = min(maxAllowed, r.maxY - minSize) }
                if abs(r.maxY - oldY) < tol { minAllowed = max(minAllowed, r.minY + minSize) }
            }
            targetY = max(minAllowed, min(targetY, maxAllowed))

            for i in 0..<newLayout.zones.count {
                let originalR = originalLayout.zones[i].absoluteRect(in: vf)
                var r = originalR
                // X may already have been mutated for this zone above — preserve it.
                let xRect = newLayout.zones[i].absoluteRect(in: vf)
                r.origin.x = xRect.origin.x
                r.size.width = xRect.size.width
                var changed = false
                if abs(originalR.minY - oldY) < tol {
                    r.size.height = originalR.maxY - targetY
                    r.origin.y = targetY
                    changed = true
                }
                if abs(originalR.maxY - oldY) < tol {
                    r.size.height = targetY - originalR.minY
                    changed = true
                }
                if changed {
                    newLayout.zones[i].fractionalRect = FractionalRect.from(absolute: r, in: vf)
                }
            }
        }

        layout = newLayout
        ZoneStore.shared.setLayout(layout)
    }

    /// Remove a zone and let its neighbours expand into the freed space.
    ///
    /// To avoid creating overlapping zones, we only accept absorbers whose
    /// PERPENDICULAR range matches D's *exactly* (same row for L/R, same
    /// column for T/B) OR a set of touching neighbours whose perpendicular
    /// ranges collectively tile D's range. A "full-coverage" neighbour with
    /// a perpendicular range larger than D's would create an overlap when
    /// extended — so we never pick those.
    private func deleteZoneAndAbsorb(id: UUID) {
        let vf = visibleFrameInView()
        guard let deleted = layout.zones.first(where: { $0.id == id }) else { return }
        let D = deleted.absoluteRect(in: vf)
        let tol: CGFloat = 1.5

        var newLayout = layout
        newLayout.zones.removeAll { $0.id == id }

        @discardableResult
        func setMaxX(_ idx: Int, _ x: CGFloat) -> Bool {
            var r = newLayout.zones[idx].absoluteRect(in: vf)
            r.size.width = x - r.minX
            newLayout.zones[idx].fractionalRect = FractionalRect.from(absolute: r, in: vf)
            return true
        }
        @discardableResult
        func setMinX(_ idx: Int, _ x: CGFloat) -> Bool {
            var r = newLayout.zones[idx].absoluteRect(in: vf)
            r.size.width = r.maxX - x
            r.origin.x = x
            newLayout.zones[idx].fractionalRect = FractionalRect.from(absolute: r, in: vf)
            return true
        }
        @discardableResult
        func setMaxY(_ idx: Int, _ y: CGFloat) -> Bool {
            var r = newLayout.zones[idx].absoluteRect(in: vf)
            r.size.height = y - r.minY
            newLayout.zones[idx].fractionalRect = FractionalRect.from(absolute: r, in: vf)
            return true
        }
        @discardableResult
        func setMinY(_ idx: Int, _ y: CGFloat) -> Bool {
            var r = newLayout.zones[idx].absoluteRect(in: vf)
            r.size.height = r.maxY - y
            r.origin.y = y
            newLayout.zones[idx].fractionalRect = FractionalRect.from(absolute: r, in: vf)
            return true
        }

        /// Returns indices of neighbours touching `axisStart`/`axisEnd`
        /// (perpendicular start/end of D) that — together — tile that range
        /// without overlap and without exceeding D's range. Nil if no clean
        /// tiling exists. Use to absorb deletion safely.
        func cleanTiling(
            touchingPredicate: (NSRect) -> Bool,
            perpMin: (NSRect) -> CGFloat,
            perpMax: (NSRect) -> CGFloat,
            rangeMin: CGFloat,
            rangeMax: CGFloat
        ) -> [Int]? {
            var candidates: [(idx: Int, lo: CGFloat, hi: CGFloat)] = []
            for (i, zone) in newLayout.zones.enumerated() {
                let r = zone.absoluteRect(in: vf)
                guard touchingPredicate(r) else { continue }
                let lo = perpMin(r)
                let hi = perpMax(r)
                // Reject neighbours that extend OUTSIDE D's perpendicular range —
                // those would overlap existing zones when we extend them.
                if lo < rangeMin - tol || hi > rangeMax + tol { return nil }
                candidates.append((i, lo, hi))
            }
            if candidates.isEmpty { return nil }
            // Sort & verify contiguous tiling of [rangeMin, rangeMax].
            candidates.sort { $0.lo < $1.lo }
            var covered = rangeMin
            for c in candidates {
                if c.lo > covered + tol { return nil }   // gap
                if c.lo < covered - tol { return nil }   // overlap
                covered = c.hi
            }
            return abs(covered - rangeMax) < tol ? candidates.map { $0.idx } : nil
        }

        let leftIdxs = cleanTiling(
            touchingPredicate: { abs($0.maxX - D.minX) < tol },
            perpMin: { $0.minY }, perpMax: { $0.maxY },
            rangeMin: D.minY, rangeMax: D.maxY
        )
        let rightIdxs = cleanTiling(
            touchingPredicate: { abs($0.minX - D.maxX) < tol },
            perpMin: { $0.minY }, perpMax: { $0.maxY },
            rangeMin: D.minY, rangeMax: D.maxY
        )
        let aboveIdxs = cleanTiling(  // perpendicular = X (zone is above D, minY == D.maxY)
            touchingPredicate: { abs($0.minY - D.maxY) < tol },
            perpMin: { $0.minX }, perpMax: { $0.maxX },
            rangeMin: D.minX, rangeMax: D.maxX
        )
        let belowIdxs = cleanTiling(
            touchingPredicate: { abs($0.maxY - D.minY) < tol },
            perpMin: { $0.minX }, perpMax: { $0.maxX },
            rangeMin: D.minX, rangeMax: D.maxX
        )

        if let L = leftIdxs, let R = rightIdxs {
            let mid = D.midX
            L.forEach { setMaxX($0, mid) }
            R.forEach { setMinX($0, mid) }
        } else if let L = leftIdxs {
            L.forEach { setMaxX($0, D.maxX) }
        } else if let R = rightIdxs {
            R.forEach { setMinX($0, D.minX) }
        } else if let A = aboveIdxs, let B = belowIdxs {
            let mid = D.midY
            A.forEach { setMinY($0, mid) }
            B.forEach { setMaxY($0, mid) }
        } else if let A = aboveIdxs {
            A.forEach { setMinY($0, D.minY) }
        } else if let B = belowIdxs {
            B.forEach { setMaxY($0, D.maxY) }
        }
        // Else: no safe absorber — leave the gap. User can drag a neighbour edge.

        ZoneStore.shared.setLayout(newLayout)
        layout = newLayout
    }

    /// Replace `zone` with two equal halves. `vertical=true` means a vertical
    /// split (left/right); false means horizontal (top/bottom).
    /// The click position is intentionally ignored — equal halves match the
    /// FancyZones split behaviour and feel predictable.
    private func splitZone(_ zone: Zone, in rect: NSRect, at p: NSPoint, vertical: Bool) {
        _ = p
        let vf = visibleFrameInView()
        var first: NSRect
        var second: NSRect
        if vertical {
            let cut = rect.midX
            first  = NSRect(x: rect.minX, y: rect.minY, width: cut - rect.minX, height: rect.height)
            second = NSRect(x: cut,       y: rect.minY, width: rect.maxX - cut, height: rect.height)
        } else {
            let cut = rect.midY
            // In Cocoa coords y grows upward; "top" is the maxY part.
            first  = NSRect(x: rect.minX, y: cut,       width: rect.width, height: rect.maxY - cut)
            second = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut - rect.minY)
        }
        let zoneA = Zone(
            name: vertical ? "\(zone.name) L" : "\(zone.name) T",
            fractionalRect: FractionalRect.from(absolute: first, in: vf)
        )
        let zoneB = Zone(
            name: vertical ? "\(zone.name) R" : "\(zone.name) B",
            fractionalRect: FractionalRect.from(absolute: second, in: vf)
        )
        var newLayout = layout
        newLayout.zones.removeAll { $0.id == zone.id }
        newLayout.zones.append(contentsOf: [zoneA, zoneB])
        ZoneStore.shared.setLayout(newLayout)
        layout = newLayout
        selectedZoneID = nil
        needsDisplay = true
    }

    private func updateZone(id: UUID, mutate: (inout Zone, NSRect) -> Void) {
        let vf = visibleFrameInView()
        guard var zone = layout.zones.first(where: { $0.id == id }) else { return }
        mutate(&zone, vf)
        ZoneStore.shared.upsertZone(zone, screenID: screenID)
        layout = ZoneStore.shared.layout(for: screenID)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)

        // Subtle dimmer over the whole screen.
        NSColor(calibratedWhite: 0, alpha: 0.25).setFill()
        bounds.fill()

        // Visible-frame guides (menu bar / dock excluded).
        let vf = visibleFrameInView()
        NSColor.white.withAlphaComponent(0.08).setStroke()
        let path = NSBezierPath(rect: vf)
        path.lineWidth = 2
        path.stroke()

        // Visual gap so adjacent zones look like distinct tiles. The HIT TEST
        // still uses the full rect, so clicking in the visual gap between two
        // zones lands on the nearest zone's edge band (resize) — which is what
        // the user wants when grabbing a shared divider.
        let visualInset: CGFloat = 4

        for (zone, rect) in zoneRectsInView() {
            let drawn = rect.insetBy(dx: visualInset, dy: visualInset)
            let isSelected = zone.id == selectedZoneID
            let fillColor = (isSelected ? NSColor.systemBlue : NSColor.systemTeal).withAlphaComponent(0.25)
            let strokeColor = (isSelected ? NSColor.systemBlue : NSColor.systemTeal).withAlphaComponent(0.95)
            fillColor.setFill()
            NSBezierPath(roundedRect: drawn, xRadius: 10, yRadius: 10).fill()
            strokeColor.setStroke()
            let stroke = NSBezierPath(roundedRect: drawn, xRadius: 10, yRadius: 10)
            stroke.lineWidth = isSelected ? 3 : 2
            stroke.stroke()

            // Label.
            let attr: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let label = NSAttributedString(string: zone.name, attributes: attr)
            let size = label.size()
            label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }

        // Drag-create preview.
        if case let .create(start, current) = drag {
            let r = NSRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(current.x - start.x),
                height: abs(current.y - start.y)
            )
            NSColor.systemYellow.withAlphaComponent(0.25).setFill()
            r.fill()
            NSColor.systemYellow.setStroke()
            let p = NSBezierPath(rect: r); p.lineWidth = 2; p.stroke()
        }

        // Help banner.
        let help = "Click+drag empty to create  ·  drag inside a zone to move  ·  drag edges/corners to resize  ·  ⇧Click=split vertical  ·  ⌃Click=split horizontal  ·  Delete to remove  ·  ⌘R reset  ·  Esc"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let banner = NSAttributedString(string: help, attributes: attrs)
        let size = banner.size()
        let pad: CGFloat = 14
        let bg = NSRect(x: vf.midX - size.width/2 - pad, y: vf.maxY - 60, width: size.width + pad*2, height: size.height + pad)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 8, yRadius: 8).fill()
        banner.draw(at: NSPoint(x: bg.minX + pad, y: bg.minY + pad/2))

        // Done button (always clickable — guaranteed escape hatch).
        let doneRect = doneButtonRect()
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: doneRect, xRadius: 18, yRadius: 18).fill()
        let doneLabel = NSAttributedString(
            string: "Done",
            attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        )
        let labelSize = doneLabel.size()
        doneLabel.draw(at: NSPoint(
            x: doneRect.midX - labelSize.width / 2,
            y: doneRect.midY - labelSize.height / 2
        ))
    }
}

private extension Zone {
    func absoluteFractionalRect(in vf: NSRect) -> NSRect {
        NSRect(
            x: vf.minX + fractionalRect.x * vf.width,
            y: vf.minY + fractionalRect.y * vf.height,
            width: fractionalRect.width * vf.width,
            height: fractionalRect.height * vf.height
        )
    }
}
