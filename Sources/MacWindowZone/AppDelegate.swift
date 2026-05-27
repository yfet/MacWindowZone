import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var dragSnapEnabled = true
    private var restorerEnabled = true
    private var axSubsystemsStarted = false
    private var trustPollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.line("=== app launched (build: \(Bundle.main.bundleURL.path)) ===")
        buildStatusItem()

        // Hotkeys (Carbon) do not need Accessibility — register immediately.
        HotkeyManager.shared.register()

        // Silent check at launch — we never auto-trigger the system prompt.
        // The status item shows whether AX is granted, and the menu has an
        // explicit "Request Accessibility Access" item the user can click to
        // get the prompt. If granted, nothing to do; otherwise we poll.
        let trusted = WindowAX.ensureAccessibilityTrusted(prompt: false)
        Log.line("accessibility trusted at launch: \(trusted)")
        if trusted {
            startAXSubsystems()
        } else {
            startTrustPolling()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshMenu),
            name: .zoneEditorStateChanged,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyManager.shared.unregister()
        if axSubsystemsStarted {
            DragSnapController.shared.stop()
            WindowRestorer.shared.stop()
        }
        trustPollTimer?.invalidate()
    }

    // MARK: - Accessibility lifecycle

    private func startAXSubsystems() {
        guard !axSubsystemsStarted else { return }
        axSubsystemsStarted = true
        Log.line("starting AX subsystems (dragSnap=\(dragSnapEnabled) restorer=\(restorerEnabled))")
        if dragSnapEnabled  { DragSnapController.shared.start() }
        if restorerEnabled  { WindowRestorer.shared.start() }
        refreshMenu()
    }

    private func startTrustPolling() {
        Log.line("trust polling started — waiting for Accessibility to be granted")
        trustPollTimer?.invalidate()
        trustPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if WindowAX.ensureAccessibilityTrusted(prompt: false) {
                Log.line("accessibility granted via polling — starting subsystems")
                timer.invalidate()
                self.trustPollTimer = nil
                self.startAXSubsystems()
            }
        }
    }

    // MARK: - Status item

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "MacWindowZone")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "MacWindowZone"
        }
        self.statusItem = item
        refreshMenu()
    }

    @objc private func refreshMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()

        let editorTitle = ZoneEditorController.shared.isActive ? "Finish Editing Zones" : "Edit Zones…"
        menu.addItem(withTitle: editorTitle, action: #selector(toggleEditor), keyEquivalent: "e").target = self

        menu.addItem(.separator())

        // Snap submenu for the focused window — current screen's zones.
        let snapMenu = NSMenu(title: "Snap Focused Window")
        let snapItem = NSMenuItem(title: "Snap Focused Window", action: nil, keyEquivalent: "")
        snapItem.submenu = snapMenu
        menu.addItem(snapItem)
        let layouts = ZoneStore.shared.config.layouts.values.sorted(by: { $0.screenID < $1.screenID })
        for layout in layouts {
            let screenName = ScreenManager.screen(for: layout.screenID)?.localizedName ?? layout.screenID
            let header = NSMenuItem(title: "— \(screenName) —", action: nil, keyEquivalent: "")
            header.isEnabled = false
            snapMenu.addItem(header)
            for (idx, zone) in layout.zones.enumerated() {
                let label = "\(zone.name)" + (idx < 9 ? "   ⌃⌥\(idx + 1)" : "")
                let m = NSMenuItem(title: label, action: #selector(snapToZoneItem(_:)), keyEquivalent: "")
                m.representedObject = ["zone": zone.id.uuidString, "screen": layout.screenID]
                m.target = self
                snapMenu.addItem(m)
            }
        }

        menu.addItem(.separator())

        // Gap submenu.
        let gapMenu = NSMenu(title: "Gap Between Windows")
        let gapItem = NSMenuItem(
            title: String(format: "Gap Between Windows: %.0f px", Settings.shared.gap),
            action: nil,
            keyEquivalent: ""
        )
        gapItem.submenu = gapMenu
        menu.addItem(gapItem)
        for preset: CGFloat in [0, 2, 4, 6, 8, 12, 16, 24] {
            let m = NSMenuItem(
                title: "\(Int(preset)) px",
                action: #selector(setGapFromMenu(_:)),
                keyEquivalent: ""
            )
            m.representedObject = preset
            m.state = abs(Settings.shared.gap - preset) < 0.5 ? .on : .off
            m.target = self
            gapMenu.addItem(m)
        }
        gapMenu.addItem(.separator())
        let customGap = NSMenuItem(title: "Custom…", action: #selector(promptCustomGap), keyEquivalent: "")
        customGap.target = self
        gapMenu.addItem(customGap)

        let dragItem = NSMenuItem(
            title: "Snap on Drag",
            action: #selector(toggleDragSnap),
            keyEquivalent: ""
        )
        dragItem.state = dragSnapEnabled ? .on : .off
        dragItem.target = self
        menu.addItem(dragItem)

        // Modifier picker for drag-snap.
        let modMenu = NSMenu(title: "Drag Modifier")
        let modItem = NSMenuItem(
            title: "Drag Modifier: \(Settings.shared.snapModifier.displayName)",
            action: nil,
            keyEquivalent: ""
        )
        modItem.submenu = modMenu
        menu.addItem(modItem)
        for mod in SnapModifier.allCases {
            let m = NSMenuItem(
                title: mod.displayName,
                action: #selector(setSnapModifierFromMenu(_:)),
                keyEquivalent: ""
            )
            m.representedObject = mod.rawValue
            m.state = (mod == Settings.shared.snapModifier) ? .on : .off
            m.target = self
            modMenu.addItem(m)
        }

        let restoreItem = NSMenuItem(
            title: "Restore Windows on Launch",
            action: #selector(toggleRestorer),
            keyEquivalent: ""
        )
        restoreItem.state = restorerEnabled ? .on : .off
        restoreItem.target = self
        menu.addItem(restoreItem)

        // "Ignored for auto-restore" submenu — apps whose session manager
        // (browsers, mostly) gets disturbed by setFrame at launch.
        let ignoredMenu = NSMenu(title: "Ignored for Auto-Restore")
        let ignoredItem = NSMenuItem(
            title: "Ignored for Auto-Restore (\(Settings.shared.ignoredForRestore.count))",
            action: nil,
            keyEquivalent: ""
        )
        ignoredItem.submenu = ignoredMenu
        menu.addItem(ignoredItem)

        // Known browser presets — checkable so user can toggle each.
        let browserPresets: [(String, String)] = [
            ("Google Chrome",          "com.google.Chrome"),
            ("Microsoft Edge",         "com.microsoft.edgemac"),
            ("Brave",                  "com.brave.Browser"),
            ("Safari",                 "com.apple.Safari"),
            ("Firefox",                "org.mozilla.firefox"),
            ("Arc",                    "com.thebrowser.Browser"),
            ("Vivaldi",                "com.vivaldi.Vivaldi"),
            ("Opera",                  "com.operasoftware.Opera")
        ]
        for (name, bundle) in browserPresets {
            let m = NSMenuItem(title: name, action: #selector(toggleIgnoredBundle(_:)), keyEquivalent: "")
            m.representedObject = bundle
            m.state = Settings.shared.ignoredForRestore.contains(bundle) ? .on : .off
            m.target = self
            ignoredMenu.addItem(m)
        }
        ignoredMenu.addItem(.separator())
        let addFront = NSMenuItem(title: "Add Frontmost App", action: #selector(addFrontmostToIgnored), keyEquivalent: "")
        addFront.target = self
        ignoredMenu.addItem(addFront)
        let resetIgn = NSMenuItem(title: "Reset to Default (browsers)", action: #selector(resetIgnoredToDefault), keyEquivalent: "")
        resetIgn.target = self
        ignoredMenu.addItem(resetIgn)

        menu.addItem(.separator())

        // Live status indicator at the top of the diagnostics block.
        let axGranted = WindowAX.ensureAccessibilityTrusted(prompt: false)
        let statusTitle: String
        if axGranted && axSubsystemsStarted {
            statusTitle = "✓ Accessibility granted · snap ready"
        } else if axGranted {
            statusTitle = "⚠︎ Accessibility granted · subsystems not started"
        } else {
            statusTitle = "✗ Accessibility NOT granted — drag-snap won't work"
        }
        let statusItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        let loginItem = NSMenuItem(
            title: LaunchAtLogin.requiresApproval
                ? "Launch at Login (approve in Settings ▸ Login Items)"
                : "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        loginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(withTitle: "Reset Zones on Current Screen", action: #selector(resetCurrentScreen), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Forget All Window Positions", action: #selector(forgetAllWindows), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Data Folder", action: #selector(openDataFolder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Debug Log", action: #selector(openDebugLog), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Request Accessibility Access", action: #selector(promptAccessibility), keyEquivalent: "").target = self

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MacWindowZone", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.menu = menu
    }

    // MARK: - Actions

    @objc private func toggleEditor() {
        ZoneEditorController.shared.toggle()
        refreshMenu()
    }

    @objc private func toggleDragSnap() {
        dragSnapEnabled.toggle()
        DragSnapController.shared.isEnabled = dragSnapEnabled
        refreshMenu()
    }

    @objc private func toggleRestorer() {
        restorerEnabled.toggle()
        if restorerEnabled {
            WindowRestorer.shared.start()
        } else {
            WindowRestorer.shared.stop()
        }
        refreshMenu()
    }

    @objc private func snapToZoneItem(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let zoneIDString = info["zone"], let zoneID = UUID(uuidString: zoneIDString),
              let screenID = info["screen"],
              let screen = ScreenManager.screen(for: screenID) else { return }
        let layout = ZoneStore.shared.layout(for: screenID)
        guard let zone = layout.zones.first(where: { $0.id == zoneID }) else { return }
        guard let win = WindowAX.focusedWindow() else { return }
        Snapper.snap(window: win, to: zone, on: screen)
    }

    @objc private func toggleIgnoredBundle(_ sender: NSMenuItem) {
        guard let bundle = sender.representedObject as? String else { return }
        Settings.shared.toggleIgnored(bundleID: bundle)
        refreshMenu()
    }

    @objc private func addFrontmostToIgnored() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundle = front.bundleIdentifier else { return }
        if bundle == Bundle.main.bundleIdentifier { return }
        Settings.shared.ignoredForRestore.insert(bundle)
        refreshMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        let result: Result<Void, Error> = LaunchAtLogin.isEnabled
            ? LaunchAtLogin.disable()
            : LaunchAtLogin.enable()
        switch result {
        case .success:
            Log.line("Launch-at-login toggled. New status: \(LaunchAtLogin.statusDescription)")
        case .failure(let error):
            Log.line("Launch-at-login toggle failed: \(error)")
            let alert = NSAlert()
            alert.messageText = "Couldn't update Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nYou can manage login items manually in System Settings ▸ General ▸ Login Items."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        refreshMenu()
    }

    @objc private func resetIgnoredToDefault() {
        Settings.shared.ignoredForRestore = Settings.defaultIgnoredForRestore
        refreshMenu()
    }

    @objc private func setSnapModifierFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mod = SnapModifier(rawValue: raw) else { return }
        Settings.shared.snapModifier = mod
        refreshMenu()
    }

    @objc private func setGapFromMenu(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? CGFloat else { return }
        Settings.shared.gap = value
        refreshMenu()
    }

    @objc private func promptCustomGap() {
        let alert = NSAlert()
        alert.messageText = "Gap between windows (points)"
        alert.informativeText = "Half of this value is inset on each side of every snap target."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = String(format: "%.0f", Settings.shared.gap)
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            if let v = Double(field.stringValue.trimmingCharacters(in: .whitespaces)), v >= 0, v < 200 {
                Settings.shared.gap = CGFloat(v)
                refreshMenu()
            }
        }
    }

    @objc private func resetCurrentScreen() {
        guard let screen = NSScreen.main else { return }
        ZoneStore.shared.resetScreen(ScreenManager.identifier(for: screen))
        refreshMenu()
    }

    @objc private func forgetAllWindows() {
        let alert = NSAlert()
        alert.messageText = "Forget all remembered window positions?"
        alert.informativeText = "Future windows will open wherever the apps place them."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            WindowMemory.shared.clearAll()
        }
    }

    @objc private func openDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([Persistence.zonesURL])
    }

    @objc private func openDebugLog() {
        if !FileManager.default.fileExists(atPath: Log.url.path) {
            Log.line("debug log opened from menu")
        }
        NSWorkspace.shared.open(Log.url)
    }

    @objc private func promptAccessibility() {
        _ = WindowAX.ensureAccessibilityTrusted(prompt: true)
    }

    @objc private func activeSpaceChanged() {
        if ZoneEditorController.shared.isActive {
            // Re-show editor on the now-current space.
            ZoneEditorController.shared.close()
            ZoneEditorController.shared.open()
        }
    }

}
