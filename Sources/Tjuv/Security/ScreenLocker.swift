import AppKit
import Foundation
import os

/// Locks the screen the way Control-Command-Q does. Tjuv keeps monitoring and sounding the siren
/// behind the lock screen, while a thief is met with the login window instead of an unlocked session.
///
/// macOS has no public API for locking the session. `SACLockScreenImmediate` in the private login
/// framework is looked up at run time, so if a future macOS drops it the setting degrades gracefully.
enum ScreenLocker {
    private typealias LockFunction = @convention(c) () -> Int32

    private static let log = Logger(subsystem: "com.mj0lken.tjuv", category: "lock")
    private static let frameworkPath = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"

    private static let lockFunction: LockFunction? = {
        guard let handle = dlopen(frameworkPath, RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate")
        else { return nil }
        return unsafeBitCast(symbol, to: LockFunction.self)
    }()

    static var isAvailable: Bool { lockFunction != nil }

    /// Returns whether an external display is connected alongside the built-in screen.
    static var hasExternalDisplay: Bool {
        NSScreen.screens.count > 1
    }

    /// Locks the macOS session immediately. Returns whether the lock succeeded.
    @discardableResult
    static func lock(reason: String) -> Bool {
        guard let lockFunction else {
            log.error("Can't lock the screen: SACLockScreenImmediate isn't available on this macOS")
            return false
        }
        let status = lockFunction()
        guard status == 0 else {
            log.error("Locking the screen failed with status \(status)")
            return false
        }
        log.notice("Locked the screen (\(reason, privacy: .public))")
        return true
    }
}

/// Tracks lid state so Tjuv locks the screen once per lid closure while armed.
enum LidLockState: Sendable, Equatable {
    case unknown
    case open
    case closed
    case closedHandled

    func shouldLock(
        isEnabled: Bool,
        isArmed: Bool,
        isLidClosed: Bool,
        lidSleepDisabledByUs: Bool,
        hasExternalDisplay: Bool
    ) -> Bool {
        guard isLidClosed, self == .open || self == .closed else { return false }
        return isEnabled && isArmed && lidSleepDisabledByUs && !hasExternalDisplay
    }

    func next(isLidClosed: Bool, locked: Bool) -> LidLockState {
        guard isLidClosed else { return .open }
        return self == .unknown || self == .closedHandled || locked ? .closedHandled : .closed
    }
}
