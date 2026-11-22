// Launch at login through SMAppService.mainApp (macOS 13+; works for the bundled app only).
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// True when the user must approve the item in System Settings › Login Items.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Returns the state that is actually in effect afterwards.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            // Unsigned or unbundled builds can't register; leave the toggle where the system says it is.
        }
        return isEnabled
    }
}
