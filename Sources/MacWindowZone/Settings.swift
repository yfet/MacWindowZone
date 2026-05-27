import Foundation
import AppKit

/// What the user must hold (or not hold) while dragging a window to trigger the snap overlay.
enum SnapModifier: String, CaseIterable {
    case none      // any window drag activates the overlay
    case shift
    case option
    case command
    case control
    case disabled  // never auto-snap on drag

    var displayName: String {
        switch self {
        case .none:     return "No modifier (always)"
        case .shift:    return "Shift (⇧)"
        case .option:   return "Option (⌥)"
        case .command:  return "Command (⌘)"
        case .control:  return "Control (⌃)"
        case .disabled: return "Disabled"
        }
    }

    func isSatisfied(by flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .none:     return true
        case .shift:    return flags.contains(.shift)
        case .option:   return flags.contains(.option)
        case .command:  return flags.contains(.command)
        case .control:  return flags.contains(.control)
        case .disabled: return false
        }
    }
}

/// User-tunable runtime settings. Persisted to UserDefaults.
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let gap = "MWZ.gap"
        static let snapModifier = "MWZ.snapModifier"
        static let restoreIgnored = "MWZ.restoreIgnored"
    }

    /// Bundle IDs whose windows must NOT be auto-restored on launch.
    /// Browsers ship here by default because attaching AX observers and
    /// calling `setFrame` during their startup disrupts session/tab restoration.
    static let defaultIgnoredForRestore: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "com.thebrowser.Browser",      // Arc
        "company.thebrowser.Browser",  // Arc (older)
        "com.operasoftware.Opera",
        "com.operasoftware.OperaGX",
        "com.vivaldi.Vivaldi"
    ]

    /// Total gap (in points) between two adjacent windows snapped to neighbouring zones.
    /// Half of this is inset on each side of every snap target.
    /// Default: 4 points.
    var gap: CGFloat {
        didSet {
            defaults.set(Double(gap), forKey: Keys.gap)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    /// Modifier required while dragging a window to activate the snap overlay.
    /// Default: `.none` (FancyZones-style — drag any window, overlay shows).
    var snapModifier: SnapModifier {
        didSet {
            defaults.set(snapModifier.rawValue, forKey: Keys.snapModifier)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    /// Set of bundle IDs whose windows are NOT auto-restored on launch.
    var ignoredForRestore: Set<String> {
        didSet {
            defaults.set(Array(ignoredForRestore), forKey: Keys.restoreIgnored)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    func ignoresAutoRestore(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return ignoredForRestore.contains(bundleID)
    }

    func toggleIgnored(bundleID: String) {
        if ignoredForRestore.contains(bundleID) {
            ignoredForRestore.remove(bundleID)
        } else {
            ignoredForRestore.insert(bundleID)
        }
    }

    private init() {
        if defaults.object(forKey: Keys.gap) != nil {
            self.gap = CGFloat(defaults.double(forKey: Keys.gap))
        } else {
            self.gap = 4
        }
        if let raw = defaults.string(forKey: Keys.snapModifier),
           let mod = SnapModifier(rawValue: raw) {
            self.snapModifier = mod
        } else {
            self.snapModifier = .shift
        }
        if let stored = defaults.array(forKey: Keys.restoreIgnored) as? [String] {
            self.ignoredForRestore = Set(stored)
        } else {
            self.ignoredForRestore = Settings.defaultIgnoredForRestore
        }
    }
}

extension Notification.Name {
    static let settingsChanged = Notification.Name("MWZ.settingsChanged")
}
