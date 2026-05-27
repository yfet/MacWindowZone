import AppKit

/// Floating picker that lets the user apply layout templates to *one screen
/// at a time* (FancyZones-style) before entering the editor.
final class TemplatePickerWindow: NSWindow, NSWindowDelegate {

    /// Called whenever the user clicks a template tile.
    typealias OnApply = (_ template: ZoneTemplate, _ screen: NSScreen) -> Void
    /// Called when the picker is dismissed.
    /// `openEditor == true` means the user clicked "Open Editor"; `false` means Cancel/close.
    typealias OnFinish = (_ openEditor: Bool) -> Void

    private var onFinish: OnFinish?
    private var hasFinished = false

    convenience init(initialScreen: NSScreen, onApply: @escaping OnApply, onFinish: @escaping OnFinish) {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "Zone Layouts"
        isReleasedWhenClosed = false
        level = .modalPanel
        delegate = self
        self.onFinish = onFinish

        let view = TemplatePickerView(
            screens: NSScreen.screens,
            initialScreen: initialScreen,
            onApply: onApply,
            onOpenEditor: { [weak self] in self?.finish(openEditor: true)  },
            onCancel:     { [weak self] in self?.finish(openEditor: false) }
        )
        contentView = view
        center()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private func finish(openEditor: Bool) {
        guard !hasFinished else { return }
        hasFinished = true
        onFinish?(openEditor)
        onFinish = nil
        close()
    }

    func windowWillClose(_ notification: Notification) {
        if !hasFinished { finish(openEditor: false) }
    }
}

private final class TemplatePickerView: NSView {

    private let screens: [NSScreen]
    private var selectedScreen: NSScreen
    private let onApply: TemplatePickerWindow.OnApply
    private let onOpenEditor: () -> Void
    private let onCancel: () -> Void

    private var screenButtons: [NSButton] = []
    private var screenInfoLabel: NSTextField!
    private var tiles: [TemplateTile] = []
    /// Remember the last applied template per screen so the matching tile
    /// stays highlighted while that screen is selected.
    private var lastApplied: [ObjectIdentifier: ZoneTemplate] = [:]

    init(screens: [NSScreen],
         initialScreen: NSScreen,
         onApply: @escaping TemplatePickerWindow.OnApply,
         onOpenEditor: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.screens = screens
        self.selectedScreen = initialScreen
        self.onApply = onApply
        self.onOpenEditor = onOpenEditor
        self.onCancel = onCancel
        super.init(frame: NSRect(x: 0, y: 0, width: 780, height: 540))
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        // Top: screen selector.
        let header = NSTextField(labelWithString: "Apply to display:")
        header.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        header.frame = NSRect(x: 24, y: 494, width: 200, height: 20)
        addSubview(header)

        var x: CGFloat = 24
        let yButtons: CGFloat = 460
        for (i, screen) in screens.enumerated() {
            let title = "\(i + 1) — \(screen.localizedName)"
            let button = NSButton(title: title, target: self, action: #selector(selectScreen(_:)))
            button.bezelStyle = .recessed
            button.setButtonType(.pushOnPushOff)
            button.tag = i
            button.state = (screen == selectedScreen) ? .on : .off
            let width = button.attributedTitle.size().width + 36
            button.frame = NSRect(x: x, y: yButtons, width: max(120, width), height: 28)
            addSubview(button)
            screenButtons.append(button)
            x += button.frame.width + 8
        }

        // Subtitle with screen info.
        screenInfoLabel = NSTextField(labelWithString: "")
        screenInfoLabel.font = NSFont.systemFont(ofSize: 11)
        screenInfoLabel.textColor = .secondaryLabelColor
        screenInfoLabel.frame = NSRect(x: 24, y: 432, width: 700, height: 18)
        addSubview(screenInfoLabel)
        updateScreenInfo()

        // Templates section.
        let templatesHeader = NSTextField(labelWithString: "Templates")
        templatesHeader.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        templatesHeader.frame = NSRect(x: 24, y: 400, width: 200, height: 20)
        addSubview(templatesHeader)

        // 3 cols × 3 rows of tiles.
        let cols = 3
        let tileW: CGFloat = 230
        let tileH: CGFloat = 100
        let gapX: CGFloat = 16
        let gapY: CGFloat = 12
        let startX: CGFloat = 24
        let startY: CGFloat = 388 - tileH

        for (i, template) in ZoneTemplate.pickerOrder.enumerated() {
            let c = i % cols
            let r = i / cols
            let frame = NSRect(
                x: startX + CGFloat(c) * (tileW + gapX),
                y: startY - CGFloat(r) * (tileH + gapY),
                width: tileW,
                height: tileH
            )
            let tile = TemplateTile(frame: frame, template: template) { [weak self] tpl in
                guard let self else { return }
                self.onApply(tpl, self.selectedScreen)
                self.lastApplied[ObjectIdentifier(self.selectedScreen)] = tpl
                self.refreshTileSelection()
                self.flash(tile: tpl)
            }
            addSubview(tile)
            tiles.append(tile)
        }

        // Bottom actions.
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(handleCancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 24, y: 18, width: 100, height: 32)
        addSubview(cancel)

        let openEditor = NSButton(title: "Open Editor", target: self, action: #selector(handleOpenEditor))
        openEditor.bezelStyle = .rounded
        openEditor.keyEquivalent = "\r"
        openEditor.frame = NSRect(x: 780 - 24 - 160, y: 18, width: 160, height: 32)
        addSubview(openEditor)

        let hint = NSTextField(labelWithString: "Click a template to apply it to the selected display. You can apply different templates to different displays.")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 140, y: 24, width: 460, height: 18)
        hint.alignment = .center
        addSubview(hint)
    }

    private func updateScreenInfo() {
        let f = selectedScreen.frame
        let scale = selectedScreen.backingScaleFactor
        screenInfoLabel.stringValue = String(
            format: "%.0f × %.0f @ %.0fx — origin %.0f, %.0f",
            f.width, f.height, scale, f.minX, f.minY
        )
    }

    @objc private func selectScreen(_ sender: NSButton) {
        selectedScreen = screens[sender.tag]
        for (i, b) in screenButtons.enumerated() {
            b.state = (i == sender.tag) ? .on : .off
        }
        updateScreenInfo()
        refreshTileSelection()
    }

    private func refreshTileSelection() {
        let active = lastApplied[ObjectIdentifier(selectedScreen)]
        for tile in tiles {
            tile.setSelected(tile.template == active)
        }
    }

    @objc private func handleOpenEditor() { onOpenEditor() }
    @objc private func handleCancel()      { onCancel() }

    /// Briefly pulse the tile after a successful apply.
    private func flash(tile applied: ZoneTemplate) {
        guard let tile = tiles.first(where: { $0.template == applied }) else { return }
        tile.flashApplied()
    }
}

/// Clickable tile that shows a template thumbnail + label.
private final class TemplateTile: NSView {
    fileprivate let template: ZoneTemplate
    private let onClick: (ZoneTemplate) -> Void
    private var isSelected = false
    private var isHovered = false

    init(frame: NSRect, template: ZoneTemplate, onClick: @escaping (ZoneTemplate) -> Void) {
        self.template = template
        self.onClick = onClick
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        setupSubviews()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        refreshAppearance()
    }

    private func refreshAppearance() {
        if isSelected {
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.borderWidth = 2.5
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        } else if isHovered {
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.borderWidth = 2
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        } else {
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.borderWidth = 1
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }

    private func setupSubviews() {
        let thumbSize = NSSize(width: 132, height: 64)
        let imageView = NSImageView(frame: NSRect(
            x: bounds.midX - thumbSize.width / 2,
            y: bounds.height - 10 - thumbSize.height,
            width: thumbSize.width,
            height: thumbSize.height
        ))
        imageView.image = template.thumbnail(size: thumbSize)
        imageView.imageScaling = .scaleNone
        addSubview(imageView)

        let label = NSTextField(labelWithString: template.displayName)
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.frame = NSRect(x: 8, y: 8, width: bounds.width - 16, height: 16)
        addSubview(label)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refreshAppearance()
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refreshAppearance()
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        onClick(template)
    }

    func flashApplied() {
        let original = layer?.backgroundColor
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.refreshAppearance()
            _ = original
        }
    }
}
