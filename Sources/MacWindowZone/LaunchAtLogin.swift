import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` (macOS 13+). Registers the app
/// as a login item so macOS launches it automatically at user login.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True if macOS reports the registration as requiring user approval in
    /// System Settings → General → Login Items.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:           return "On"
        case .requiresApproval:  return "Requires approval"
        case .notFound:          return "Not registered"
        case .notRegistered:     return "Off"
        @unknown default:        return "Unknown"
        }
    }

    @discardableResult
    static func enable() -> Result<Void, Error> {
        do {
            try SMAppService.mainApp.register()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    @discardableResult
    static func disable() -> Result<Void, Error> {
        do {
            try SMAppService.mainApp.unregister()
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
