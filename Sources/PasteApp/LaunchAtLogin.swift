import Foundation
import ServiceManagement

/// Login item backed by `SMAppService`. A SwiftPM executable has no bundle
/// for LaunchServices to register, so the setting is a no-op under
/// `swift run` and only takes effect inside a real .app.
enum LaunchAtLogin {
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Returns false only when the system rejected the change, so the caller
    /// can roll the stored setting back instead of showing a dead toggle.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard isAvailable else { return false }
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
                if service.status == .requiresApproval {
                    NSLog("[paste] login item needs approval in System Settings")
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
            return true
        } catch {
            NSLog("[paste] login item update failed: %@", String(describing: error))
            return false
        }
    }
}
