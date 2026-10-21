import AppKit
import Foundation
import IOKit

/// Checks whether macOS "Find My Mac" is enabled in NVRAM (`fmm-mobileme-token-FMM`).
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
                return "Enabled (FMM token present in NVRAM)"
            case .disabled:
                return "Disabled (no FMM token in NVRAM)"
            }
        }
    }

    /// Reads the `fmm-mobileme-token-FMM` property directly from `IODeviceTree:/options` in NVRAM.
    static var currentStatus: Status {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/options")
        guard entry != MACH_PORT_NULL else { return .disabled }
        defer { IOObjectRelease(entry) }

        if let prop = IORegistryEntryCreateCFProperty(
            entry,
            "fmm-mobileme-token-FMM" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() {
            if let data = prop as? Data, !data.isEmpty {
                return .enabled
            }
            if let str = prop as? String, !str.isEmpty {
                return .enabled
            }
        }
        return .disabled
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
