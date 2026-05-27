import AppKit
import Carbon.HIToolbox

/// Registers global hotkeys ⌃⌥1 .. ⌃⌥9 that snap the focused window to
/// zone 1..9 on the screen currently containing the window.
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var refs: [EventHotKeyRef?] = []
    private var handlerRef: EventHandlerRef?
    private var registered = false

    private static let signature: OSType = {
        // 4-char 'MWZN' as OSType
        return UInt32(bitPattern: 0x4D575A4E) // 'MWZN'
    }()

    func register() {
        guard !registered else { return }
        registered = true

        let modifiers: UInt32 = UInt32(controlKey | optionKey)
        let keyCodes: [Int] = [
            kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3,
            kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6,
            kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9
        ]

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, userData) -> OSStatus in
                guard let eventRef, let userData else { return noErr }
                var hkID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                if status == noErr {
                    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                    DispatchQueue.main.async {
                        manager.handle(id: hkID.id)
                    }
                }
                return noErr
            },
            1,
            &eventType,
            context,
            &handlerRef
        )

        for (index, keyCode) in keyCodes.enumerated() {
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index + 1))
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(keyCode), modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr {
                refs.append(ref)
            } else {
                NSLog("Failed to register hotkey \(index + 1): \(status)")
            }
        }
    }

    func unregister() {
        for ref in refs { if let r = ref { UnregisterEventHotKey(r) } }
        refs.removeAll()
        if let handler = handlerRef { RemoveEventHandler(handler); handlerRef = nil }
        registered = false
    }

    private func handle(id: UInt32) {
        let zoneIndex = Int(id)
        Snapper.snapFocused(toZoneIndex: zoneIndex)
    }
}
