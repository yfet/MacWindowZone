import AppKit
import ApplicationServices

/// Observes app launches and newly created windows, then restores any
/// remembered placement (zone or absolute frame).
final class WindowRestorer {
    static let shared = WindowRestorer()

    private var observers: [pid_t: AXObserver] = [:]
    private var enabled = false

    func start() {
        guard !enabled else { return }
        enabled = true

        // Track future launches.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        // Bootstrap from currently running apps. We skip ignored apps entirely
        // — no AX observer, no kAXWindows queries — so their session state
        // (browser tabs/pinned tabs/position memory) stays untouched.
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if shouldSkip(app: app) { continue }
            attach(to: app)
            restoreExistingWindows(of: app)
        }
    }

    private func shouldSkip(app: NSRunningApplication) -> Bool {
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return true }
        if Settings.shared.ignoresAutoRestore(bundleID: app.bundleIdentifier) {
            Log.line("WindowRestorer: skipping \(app.bundleIdentifier ?? "?") (in ignore list)")
            return true
        }
        return false
    }

    func stop() {
        guard enabled else { return }
        enabled = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for (_, observer) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observers.removeAll()
    }

    // MARK: - Per-app attachment

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if shouldSkip(app: app) { return }
        // Give the app a moment to create its initial windows.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.attach(to: app)
            self.restoreExistingWindows(of: app)
        }
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if let observer = observers.removeValue(forKey: app.processIdentifier) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }

    private func attach(to app: NSRunningApplication) {
        guard observers[app.processIdentifier] == nil else { return }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        // Browsers and other apps that manage their own session state can be
        // disrupted by AX observers + setFrame calls during their startup
        // (e.g. Chrome losing tabs / pinned tabs). Honour the ignore list.
        if Settings.shared.ignoresAutoRestore(bundleID: app.bundleIdentifier) {
            return
        }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let restorer = Unmanaged<WindowRestorer>.fromOpaque(refcon).takeUnretainedValue()
            let notifString = notification as String
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                restorer.handle(element: element, notification: notifString)
            }
        }
        let result = AXObserverCreate(app.processIdentifier, callback, &observer)
        guard result == .success, let observer else { return }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let context = Unmanaged.passUnretained(self).toOpaque()
        // Only subscribe to window-creation. Focus changes fire too often during
        // normal use and trigger setFrame on every Chrome tab focus etc.
        AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, context)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[app.processIdentifier] = observer
    }

    // MARK: - Restore

    fileprivate func handle(element: AXUIElement, notification: String) {
        // The element here is the AXUIElement that fired the notification.
        // For window-created it is the window itself; for focused-changed it
        // is the application element.
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        let bundleID = app.bundleIdentifier ?? "unknown.\(pid)"

        let role = AXWindow.copyString(element, attribute: kAXRoleAttribute as CFString) ?? ""
        if role == (kAXWindowRole as String) {
            let title = AXWindow.copyString(element, attribute: kAXTitleAttribute as CFString) ?? ""
            let window = AXWindow(element: element, pid: pid, bundleIdentifier: bundleID, title: title)
            attemptRestore(window: window)
        } else {
            // Focused changed: rescan windows of that app.
            restoreExistingWindows(of: app)
        }
    }

    private func restoreExistingWindows(of app: NSRunningApplication) {
        let windows = WindowAX.windows(for: app)
        for window in windows {
            attemptRestore(window: window)
        }
    }

    private func attemptRestore(window: AXWindow) {
        if Settings.shared.ignoresAutoRestore(bundleID: window.bundleIdentifier) { return }
        guard let memory = WindowMemory.shared.lookup(bundleID: window.bundleIdentifier, windowKey: window.windowKey) else {
            return
        }
        if let zoneID = memory.zoneID,
           let screenID = memory.screenID,
           let screen = ScreenManager.screen(for: screenID) {
            let layout = ZoneStore.shared.layout(for: screenID)
            if let zone = layout.zones.first(where: { $0.id == zoneID }) {
                Snapper.snap(window: window, to: zone, on: screen)
                return
            }
        }
        if let frame = memory.lastFrame {
            window.setFrame(frame)
        }
    }
}
