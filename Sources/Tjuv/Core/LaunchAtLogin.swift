import os
import ServiceManagement

/// Thin wrapper over `SMAppService` so the menu item reflects the real login-item state.
enum LaunchAtLogin {
    private static let log = Logger(subsystem: "com.mj0lken.tjuv", category: "login")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: "on"
        case .requiresApproval: "waiting for approval in System Settings › General › Login Items"
        case .notRegistered: "off"
        case .notFound: "not found (install Tjuv.app in /Applications)"
        @unknown default: "unknown"
        }
    }

    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) -> String? {
        guard enabled != isEnabled else { return nil }
        do {
            try enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            return nil
        } catch {
            log.error("Couldn't change login item: \(error.localizedDescription, privacy: .public)")
            return "Couldn't change the login item: \(error.localizedDescription)"
        }
    }
}
