import Foundation
import AppKit

/// What the user must hold (or not hold) while dragging a window to trigger the snap overlay.
enum SnapModifier: String, CaseIterable {
    case none      // any window drag activates the overlay
    case shift
    case option
    case command
    case control
    case disabled  // never show the zone overlay on drag (edge snap has its own toggle)

    var displayName: String {
        switch self {
        case .none:     return "No modifier (always)"
        case .shift:    return "Shift (⇧)"
        case .option:   return "Option (⌥)"
        case .command:  return "Command (⌘)"
        case .control:  return "Control (⌃)"
        case .disabled: return "Disabled (zone overlay off)"
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

    /// Extra modifier held during a drag-snap to accumulate multiple zones.
    /// Control by default; Option when Control is already the snap modifier
    /// so the two gestures don't collide.
    var multiSelectFlag: NSEvent.ModifierFlags {
        self == .control ? .option : .control
    }

    func isMultiSelectSatisfied(by flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(multiSelectFlag)
    }

    /// Status-menu hint for the multi-zone drag gesture. Empty when drag-snap is disabled.
    var multiSelectHint: String {
        switch self {
        case .disabled:
            return ""
        case .control:
            return "Hold ⌥ Option while dragging to select multiple zones"
        default:
            return "Hold ⌃ Control while dragging to select multiple zones"
        }
    }
}

/// How a taller-than-wide display treats Aero-style edge snaps.
enum PortraitEdgeBehavior: String, CaseIterable {
    /// Top edge fills the screen; left/right edges split top vs bottom half.
    case topFillsSidesSplit
    /// Every edge (including the top) splits top vs bottom half.
    case allEdgesSplit
    /// Identical to landscape: top fills, left/right are left/right halves.
    case landscape

    var displayName: String {
        switch self {
        case .topFillsSidesSplit: return "Top fills, sides split top/bottom"
        case .allEdgesSplit:      return "All edges split top/bottom"
        case .landscape:          return "Same as landscape (left/right halves)"
        }
    }

    var shortName: String {
        switch self {
        case .topFillsSidesSplit: return "Top fills screen"
        case .allEdgesSplit:      return "All edges split"
        case .landscape:          return "Same as landscape"
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
        static let edgeSnapEnabled = "MWZ.edgeSnapEnabled"
        static let edgeSnapBuffer = "MWZ.edgeSnapBuffer"
        static let portraitEdgeBehavior = "MWZ.portraitEdgeBehavior"
        static let editorGridStep = "MWZ.editorGridStep"
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

    /// True when macOS's own "Drag windows to screen edges to tile" (macOS 15+)
    /// is on. It reacts to the same gestures as our edge snap, so running both
    /// makes them race on mouse-up. The key is absent until the user changes
    /// the setting, and the system default is on.
    static var nativeEdgeTilingEnabled: Bool {
        guard #available(macOS 15, *) else { return false }
        let value = CFPreferencesCopyAppValue(
            "EnableTilingByEdgeDrag" as CFString,
            "com.apple.WindowManager" as CFString
        )
        return (value as? Bool) ?? true
    }

    /// When true, dragging a window to a screen edge/corner shows an Aero-style
    /// snap preview (no zone modifier required). Defaults to off when macOS's
    /// native edge tiling is on, so the two don't fight.
    var edgeSnapEnabled: Bool {
        didSet {
            defaults.set(edgeSnapEnabled, forKey: Keys.edgeSnapEnabled)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    /// Interior margin (points) that counts as "on the edge" of a display.
    /// Wider values make snaps at the seam between extended displays hittable,
    /// since macOS does not clamp the cursor there. Default: 24.
    var edgeSnapBuffer: CGFloat {
        didSet {
            defaults.set(Double(edgeSnapBuffer), forKey: Keys.edgeSnapBuffer)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    /// Edge-snap layout used on portrait (taller-than-wide) displays.
    /// Default: top edge fills the screen; side edges split top/bottom.
    var portraitEdgeBehavior: PortraitEdgeBehavior {
        didSet {
            defaults.set(portraitEdgeBehavior.rawValue, forKey: Keys.portraitEdgeBehavior)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    /// Fixed step (points) of the zone editor's grid, anchored at the top-left
    /// of the visible frame. Zone edges snap to it while editing; screen edges
    /// and other zones' edges snap magnetically on top. 0 = grid off.
    /// Default: 16 (a multiple of the common 8-pt rhythm, fine enough to place
    /// zones freely, coarse enough to line them up by eye).
    var editorGridStep: CGFloat {
        didSet {
            defaults.set(Double(editorGridStep), forKey: Keys.editorGridStep)
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
        if defaults.object(forKey: Keys.edgeSnapEnabled) != nil {
            self.edgeSnapEnabled = defaults.bool(forKey: Keys.edgeSnapEnabled)
        } else {
            self.edgeSnapEnabled = !Settings.nativeEdgeTilingEnabled
        }
        if defaults.object(forKey: Keys.edgeSnapBuffer) != nil {
            self.edgeSnapBuffer = CGFloat(defaults.double(forKey: Keys.edgeSnapBuffer))
        } else {
            self.edgeSnapBuffer = 24
        }
        if let raw = defaults.string(forKey: Keys.portraitEdgeBehavior),
           let behavior = PortraitEdgeBehavior(rawValue: raw) {
            self.portraitEdgeBehavior = behavior
        } else {
            self.portraitEdgeBehavior = .topFillsSidesSplit
        }
        if defaults.object(forKey: Keys.editorGridStep) != nil {
            self.editorGridStep = max(0, CGFloat(defaults.double(forKey: Keys.editorGridStep)))
        } else {
            self.editorGridStep = 16
        }
    }
}

extension Notification.Name {
    static let settingsChanged = Notification.Name("MWZ.settingsChanged")
}
