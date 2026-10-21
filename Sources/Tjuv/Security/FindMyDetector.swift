import AppKit
import Foundation
import IOKit

/// Checks whether macOS "Find My Mac" is enabled via `/Library/Preferences/com.apple.FindMyMac.plist`
/// (`FMMEnabled`), the user's iCloud `MobileMeAccounts` (`FIND_MY_MAC`), or NVRAM (`fmm-mobileme-token-FMM`).
///
/// On Apple Silicon Macs, turning on **Find My Mac** and **Find My network** makes the internal
/// Bluetooth/SPU controller broadcast rotating encrypted P-224 beacons—the exact same Offline
/// Finding network protocol an Apple AirTag uses—even when the Mac is offline, asleep, or powered off.
enum FindMyDetector {
    enum Status: Equatable, Sendable {
        case enabled
        case disabled

        var isEnabled: Bool { self == .enabled }

        var menuTitle: String {
            switch self {
            case .enabled:
                return "Find My Beacon (AirTag Mode): Active"
            case .disabled:
                return "⚠️ Find My Mac is Off (Click to Enable AirTag Tracking…)"
            }
        }

        var shortSummary: String {
            switch self {
            case .enabled:
                return "Enabled (FMMEnabled / iCloud Find My Mac active)"
            case .disabled:
                return "Disabled"
            }
        }
    }

    static var currentStatus: Status {
        status(
            systemPlistEnabled: isSystemFindMyEnabled(),
            mobileMeEnabled: isMobileMeFindMyEnabled(),
            nvramEnabled: isNvramFindMyEnabled()
        )
    }

    static func status(
        systemPlistEnabled: Bool,
        mobileMeEnabled: Bool,
        nvramEnabled: Bool
    ) -> Status {
        (systemPlistEnabled || mobileMeEnabled || nvramEnabled) ? .enabled : .disabled
    }

    /// Reads `FMMEnabled` from `/Library/Preferences/com.apple.FindMyMac.plist` (used on macOS 14/15+ Apple Silicon).
    private static func isSystemFindMyEnabled() -> Bool {
        if let value = CFPreferencesCopyValue(
            "FMMEnabled" as CFString,
            "com.apple.FindMyMac" as CFString,
            kCFPreferencesAnyUser,
            kCFPreferencesCurrentHost
        ) as? Bool, value {
            return true
        }
        let plistURL = URL(fileURLWithPath: "/Library/Preferences/com.apple.FindMyMac.plist")
        if let dict = NSDictionary(contentsOf: plistURL),
           let enabled = dict["FMMEnabled"] as? Bool,
           enabled {
            return true
        }
        return false
    }

    /// Checks `FIND_MY_MAC` (`com.apple.Dataclass.DeviceLocator`) in `~/Library/Preferences/MobileMeAccounts.plist`.
    private static func isMobileMeFindMyEnabled() -> Bool {
        guard let domain = UserDefaults.standard.persistentDomain(forName: "MobileMeAccounts"),
              let accounts = domain["Accounts"] as? [[String: Any]] else {
            return false
        }
        return isMobileMeFindMyEnabled(accounts: accounts)
    }

    static func isMobileMeFindMyEnabled(accounts: [[String: Any]]) -> Bool {
        for account in accounts {
            guard let services = account["Services"] as? [[String: Any]] else { continue }
            for service in services {
                let name = service["Name"] as? String
                let id = service["ServiceID"] as? String
                if name == "FIND_MY_MAC" || id == "com.apple.Dataclass.DeviceLocator" {
                    if let enabled = service["Enabled"] as? Bool, enabled {
                        return true
                    }
                    if let enabledNum = service["Enabled"] as? NSNumber, enabledNum.boolValue {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Reads the legacy `fmm-mobileme-token-FMM` property from `IODeviceTree:/options` in NVRAM.
    private static func isNvramFindMyEnabled() -> Bool {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/options")
        guard entry != MACH_PORT_NULL else { return false }
        defer { IOObjectRelease(entry) }

        if let prop = IORegistryEntryCreateCFProperty(
            entry,
            "fmm-mobileme-token-FMM" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() {
            if let data = prop as? Data, !data.isEmpty {
                return true
            }
            if let str = prop as? String, !str.isEmpty {
                return true
            }
        }
        return false
    }

    /// Opens System Settings to the iCloud / Find My pane so the user can enable Find My Mac
    /// and Find My network.
    static func openSystemSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane?iCloud",
            "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
