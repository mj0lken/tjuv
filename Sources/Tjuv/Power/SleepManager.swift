import Foundation
import IOKit.pwr_mgt
import os

/// Manages system sleep assertions and closed-lid clamshell mode override via `pmset disablesleep`.
///
/// Safety nets (matching `thumbs-out`):
/// - Ownership (`lidSleepDisabledByTjuv`) is recorded and a dead-man's switch watchdog process is
///   started *before* `SleepDisabled` is turned on.
/// - Only a switch Tjuv turned on is ever turned off, so it coexists cleanly with `thumbs-out`.
/// - If Tjuv crashes or is killed, the watchdog restores lid sleep within ~5 seconds.
/// - On launch, a switch left on by a previous crashed run of Tjuv is restored immediately.
final class SleepManager: ObservableObject {
    static let shared = SleepManager()

    private static let log = Logger(subsystem: "com.mj0lken.tjuv", category: "sleep")
    private static let ownershipKey = "lidSleepDisabledByTjuv"
    private static let adminPrompt =
        "Tjuv wants to set up closed-lid protection so it can monitor your Mac for theft with the lid closed."
    private static let removePrompt =
        "Tjuv wants to remove closed-lid protection and restore normal lid sleep."

    @Published var closedLidProtectionEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(closedLidProtectionEnabled, forKey: "closedLidProtectionEnabled")
        }
    }

    @Published private(set) var isSetUp: Bool = false
    @Published private(set) var isBusy: Bool = false
    @Published private(set) var lastError: String?

    /// Whether `SleepDisabled` is currently on because of Tjuv.
    var isDisabledByUs: Bool {
        get { UserDefaults.standard.bool(forKey: Self.ownershipKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.ownershipKey) }
    }

    private var systemSleepAssertionID: IOPMAssertionID = 0
    private var hasActiveSleepAssertion = false
    private var watchdog: Process?

    init() {
        if UserDefaults.standard.object(forKey: "closedLidProtectionEnabled") != nil {
            closedLidProtectionEnabled = UserDefaults.standard.bool(forKey: "closedLidProtectionEnabled")
        }
        isSetUp = hasPasswordlessSudo
        cleanupPreviousSleepSettingsIfNeeded()
    }

    func refreshSetupStatus() {
        let installed = hasPasswordlessSudo
        if isSetUp != installed {
            isSetUp = installed
        }
    }

    /// Toggles closed-lid protection from the UI switch, prompting once for sudoers installation if needed.
    func setClosedLidMode(_ enabled: Bool) {
        lastError = nil
        if enabled {
            if hasPasswordlessSudo {
                isSetUp = true
                closedLidProtectionEnabled = true
                if AlarmCoordinator.shared.state != .disarmed {
                    preventSleep()
                }
            } else {
                isBusy = true
                installPasswordlessHelper { [weak self] success, err in
                    guard let self else { return }
                    self.isBusy = false
                    self.isSetUp = self.hasPasswordlessSudo
                    if success {
                        self.closedLidProtectionEnabled = true
                        if AlarmCoordinator.shared.state != .disarmed {
                            self.preventSleep()
                        }
                    } else {
                        self.closedLidProtectionEnabled = false
                        if err != "Cancelled." {
                            self.lastError = err
                        }
                    }
                }
            }
        } else {
            closedLidProtectionEnabled = false
            if isDisabledByUs {
                if setDisableSleep(enabled: false) {
                    isDisabledByUs = false
                    stopWatchdog()
                }
            }
        }
    }

    deinit {
        restoreNormalSleep()
    }

    // MARK: - Power Assertion & Lid Sleep Control

    func preventSleep() {
        if !hasActiveSleepAssertion {
            let reason = "Tjuv Anti-Theft Alarm Active" as CFString
            let status = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &systemSleepAssertionID
            )
            hasActiveSleepAssertion = (status == kIOReturnSuccess)
        }

        if closedLidProtectionEnabled && !isDisabledByUs {
            // Only flip disablesleep if something else hasn't already disabled sleep
            if !isSystemSleepCurrentlyDisabled {
                isDisabledByUs = true
                startWatchdog()
                if !setDisableSleep(enabled: true) {
                    isDisabledByUs = false
                    stopWatchdog()
                }
            }
        }
    }

    func restoreNormalSleep() {
        if hasActiveSleepAssertion {
            IOPMAssertionRelease(systemSleepAssertionID)
            systemSleepAssertionID = 0
            hasActiveSleepAssertion = false
        }

        if isDisabledByUs {
            if setDisableSleep(enabled: false) {
                isDisabledByUs = false
                stopWatchdog()
            }
        }
    }

    // MARK: - Sudoers & pmset Inspection

    /// Checks whether `sudo -n /usr/bin/pmset -a disablesleep 1` is allowed without a password.
    var hasPasswordlessSudo: Bool {
        runSync(
            LidSleepHelper.sudoPath,
            ["-n", "-l", LidSleepHelper.pmsetPath] + LidSleepHelper.pmsetArguments(disableSleep: true)
        ) == 0
    }

    /// Reads whether system-wide `SleepDisabled` (`disablesleep 1`) is currently active.
    var isSystemSleepCurrentlyDisabled: Bool {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: LidSleepHelper.pmsetPath)
        task.arguments = ["-g"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return output.contains("SleepDisabled\t\t1") || output.contains("disablesleep 1") || output.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
            }
        } catch {}
        return false
    }

    @discardableResult
    private func setDisableSleep(enabled: Bool) -> Bool {
        let args = ["-n", LidSleepHelper.pmsetPath] + LidSleepHelper.pmsetArguments(disableSleep: enabled)
        if runSync(LidSleepHelper.sudoPath, args) == 0 {
            return true
        }

        // Fallback to admin prompt if passwordless sudoers is not installed yet
        let cmd = ([LidSleepHelper.pmsetPath] + LidSleepHelper.pmsetArguments(disableSleep: enabled)).joined(separator: " ")
        let status = runSync("/usr/bin/osascript", ["-e", LidSleepHelper.administratorAppleScript(shell: cmd, prompt: Self.adminPrompt)])
        if status != 0 {
            Self.log.error("Failed to set disablesleep to \(enabled)")
        }
        return status == 0
    }

    /// Installs the `visudo`-validated `/etc/sudoers.d/tjuv` rule with one admin prompt.
    func installPasswordlessHelper(completion: @escaping (Bool, String?) -> Void) {
        let user = NSUserName()
        let script: String
        do {
            script = try LidSleepHelper.installScript(user: user)
        } catch {
            completion(false, error.localizedDescription)
            return
        }

        let appleScript = LidSleepHelper.administratorAppleScript(shell: script, prompt: Self.adminPrompt)
        DispatchQueue.global(qos: .userInitiated).async {
            let (status, err) = Self.runCapturingError("/usr/bin/osascript", ["-e", appleScript])
            DispatchQueue.main.async {
                if status == 0 {
                    completion(true, nil)
                } else if err.contains("-128") {
                    completion(false, "Cancelled.")
                } else {
                    completion(false, err.isEmpty ? "Authorization failed." : err)
                }
            }
        }
    }

    /// Restores normal lid sleep and deletes `/etc/sudoers.d/tjuv`.
    func uninstallPasswordlessHelper(completion: @escaping (Bool, String?) -> Void) {
        if isDisabledByUs {
            _ = setDisableSleep(enabled: false)
            isDisabledByUs = false
            stopWatchdog()
        }
        let appleScript = LidSleepHelper.administratorAppleScript(shell: LidSleepHelper.uninstallScript(), prompt: Self.removePrompt)
        DispatchQueue.global(qos: .userInitiated).async {
            let (status, err) = Self.runCapturingError("/usr/bin/osascript", ["-e", appleScript])
            DispatchQueue.main.async {
                if status == 0 {
                    completion(true, nil)
                } else if err.contains("-128") {
                    completion(false, "Cancelled.")
                } else {
                    completion(false, err.isEmpty ? "Could not remove sudoers rule." : err)
                }
            }
        }
    }

    private func cleanupPreviousSleepSettingsIfNeeded() {
        guard isDisabledByUs else { return }
        Self.log.notice("Re-enabling lid sleep left disabled by a previous Tjuv session")
        if setDisableSleep(enabled: false) {
            isDisabledByUs = false
        }
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        guard watchdog?.isRunning != true else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            LidSleepHelper.watchdogScript(
                appPID: ProcessInfo.processInfo.processIdentifier,
                executablePath: Bundle.main.executablePath ?? CommandLine.arguments[0]
            ),
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            watchdog = process
        } catch {
            Self.log.error("Couldn't start lid-sleep watchdog: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopWatchdog() {
        if watchdog?.isRunning == true {
            watchdog?.terminate()
        }
        watchdog = nil
    }

    // MARK: - Process Helpers

    @discardableResult
    private func runSync(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    private static func runCapturingError(_ executable: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let err = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return (process.terminationStatus, err)
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}
