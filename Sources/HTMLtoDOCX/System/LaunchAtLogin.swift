import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` (macOS 13+).
/// Lets the app register itself to launch automatically when the user logs
/// into macOS — which on a normal Mac means "every time the machine boots
/// and reaches the desktop".
enum LaunchAtLogin {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns `true` on success, `false` if the system rejected the request
    /// (e.g. the user has it disabled in System Settings → Login Items).
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status != .notRegistered {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            NSLog("[HTMLtoDOCX] LaunchAtLogin error: \(error.localizedDescription)")
            return false
        }
    }
}
