import Foundation
import AppKit

enum Persistence {
    static let appFolderName = "MacWindowZone"

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(appFolderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static var zonesURL: URL { supportDirectory.appendingPathComponent("zones.json") }
    static var memoryURL: URL { supportDirectory.appendingPathComponent("window-memory.json") }
}

final class ZoneStore {
    static let shared = ZoneStore()
    private(set) var config: ZoneConfiguration

    private init() {
        if let data = try? Data(contentsOf: Persistence.zonesURL),
           let decoded = try? JSONDecoder().decode(ZoneConfiguration.self, from: data) {
            self.config = decoded
        } else {
            self.config = ZoneConfiguration()
        }
        // Seed defaults for any new screen on first launch.
        seedDefaultsIfNeeded()
    }

    func layout(for screenID: String) -> ScreenLayout {
        if let layout = config.layouts[screenID] { return layout }
        let layout = ScreenLayout(screenID: screenID, zones: ZoneStore.defaultZones())
        config.layouts[screenID] = layout
        save()
        return layout
    }

    func setLayout(_ layout: ScreenLayout) {
        config.layouts[layout.screenID] = layout
        save()
    }

    func upsertZone(_ zone: Zone, screenID: String) {
        var layout = layout(for: screenID)
        if let idx = layout.zones.firstIndex(where: { $0.id == zone.id }) {
            layout.zones[idx] = zone
        } else {
            layout.zones.append(zone)
        }
        setLayout(layout)
    }

    func removeZone(id: UUID, screenID: String) {
        var layout = layout(for: screenID)
        layout.zones.removeAll { $0.id == id }
        setLayout(layout)
    }

    func resetScreen(_ screenID: String) {
        config.layouts[screenID] = ScreenLayout(screenID: screenID, zones: ZoneStore.defaultZones())
        save()
    }

    private func seedDefaultsIfNeeded() {
        for screen in NSScreen.screens {
            let id = ScreenManager.identifier(for: screen)
            if config.layouts[id] == nil {
                config.layouts[id] = ScreenLayout(screenID: id, zones: ZoneStore.defaultZones())
            }
        }
        save()
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: Persistence.zonesURL, options: .atomic)
        } catch {
            NSLog("ZoneStore save failed: \(error)")
        }
    }

    static func defaultZones() -> [Zone] {
        [
            Zone(name: "Left Half",  fractionalRect: .init(x: 0,   y: 0, width: 0.5, height: 1)),
            Zone(name: "Right Half", fractionalRect: .init(x: 0.5, y: 0, width: 0.5, height: 1)),
            Zone(name: "Top Right",  fractionalRect: .init(x: 0.5, y: 0,   width: 0.5, height: 0.5)),
            Zone(name: "Bottom Right", fractionalRect: .init(x: 0.5, y: 0.5, width: 0.5, height: 0.5)),
            Zone(name: "Full",       fractionalRect: .full)
        ]
    }
}

final class WindowMemory {
    static let shared = WindowMemory()
    private(set) var store: WindowMemoryStore

    private init() {
        if let data = try? Data(contentsOf: Persistence.memoryURL),
           let decoded = try? JSONDecoder().decode(WindowMemoryStore.self, from: data) {
            self.store = decoded
        } else {
            self.store = WindowMemoryStore()
        }
    }

    func remember(bundleID: String, windowKey: String, zoneID: UUID?, screenID: String?, frame: CGRect?) {
        let key = WindowMemoryStore.key(bundleID: bundleID, windowKey: windowKey)
        let entry = WindowMemoryEntry(
            bundleIdentifier: bundleID,
            windowKey: windowKey,
            zoneID: zoneID,
            screenID: screenID,
            lastFrame: frame,
            lastSeen: Date()
        )
        store.entries[key] = entry
        save()
    }

    func lookup(bundleID: String, windowKey: String) -> WindowMemoryEntry? {
        store.entries[WindowMemoryStore.key(bundleID: bundleID, windowKey: windowKey)]
    }

    func forget(bundleID: String, windowKey: String) {
        store.entries.removeValue(forKey: WindowMemoryStore.key(bundleID: bundleID, windowKey: windowKey))
        save()
    }

    func clearAll() {
        store.entries.removeAll()
        save()
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(store)
            try data.write(to: Persistence.memoryURL, options: .atomic)
        } catch {
            NSLog("WindowMemory save failed: \(error)")
        }
    }
}
