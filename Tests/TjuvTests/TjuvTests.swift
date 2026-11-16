import CoreAudio
import Foundation
import IOKit
import Testing
@testable import Tjuv

@Suite("Tjuv Anti-Theft Alarm Tests")
struct TjuvTests {

    @Test("Built-in speaker and audio device querying")
    func testBuiltInSpeakerDetection() {
        let speakerID = AudioController.shared.findBuiltInSpeakerID()
        let defaultID = AudioController.shared.getDefaultOutputDeviceID()
        if let id = speakerID {
            #expect(id > 0)
        }
        if let def = defaultID {
            #expect(def > 0)
        }
    }

    @Test("Motion detector sensitivity hierarchy")
    func testSensitivityThresholds() {
        let low = MotionSensitivity.low.accelerationThreshold
        let med = MotionSensitivity.medium.accelerationThreshold
        let high = MotionSensitivity.high.accelerationThreshold

        #expect(low > med, "Low sensitivity requires higher acceleration than Medium")
        #expect(med > high, "Medium sensitivity requires higher acceleration than High")

        let lowTilt = MotionSensitivity.low.tiltThresholdDegrees
        let medTilt = MotionSensitivity.medium.tiltThresholdDegrees
        let highTilt = MotionSensitivity.high.tiltThresholdDegrees

        #expect(lowTilt > medTilt)
        #expect(medTilt > highTilt)
    }

    @Test("Apple Silicon IMU hardware check")
    func testHardwareSensorPresence() {
        let available = MotionDetector.shared.isHardwareAvailable
        let spuService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDevice"))
        if spuService != 0 {
            IOObjectRelease(spuService)
            #expect(available == true, "Physical Apple Silicon MacBook should have SPU IMU available")
        } else {
            #expect(available == false || available == true)
        }
    }

    @Test("System triggers query without crash")
    func testSystemTriggersReadings() {
        let isClosed = SystemTriggers.shared.isLidClosed()
        #expect(isClosed == false || isClosed == true)
    }

    @Test("Alarm coordinator initial state and settings")
    func testAlarmCoordinatorInitialState() {
        let coordinator = AlarmCoordinator.shared
        coordinator.forceDisarm()
        #expect(coordinator.state == .disarmed)
        #expect(coordinator.state.isEnabled == false)

        coordinator.enterStandby()
        #expect(coordinator.state == .standby)
        #expect(coordinator.state.isEnabled == true)

        #expect(LockAndArmSource.menuButton.rawValue == "manual Lock & Arm button")
        #expect(LockAndArmSource.lidClosed.rawValue == "lid closed")
        #expect(LockAndArmSource.systemScreenLock.rawValue == "system screen lock")

        coordinator.forceDisarm()
        #expect(coordinator.state == .disarmed)

        coordinator.enterStandby()
        #expect(coordinator.state == .standby)

        coordinator.armingDelaySeconds = 5
        #expect(coordinator.armingDelaySeconds == 5)

        coordinator.countdownDurationSeconds = 5
        #expect(coordinator.countdownDurationSeconds == 5)
        #expect(coordinator.gracePeriodSeconds == 5)
    }

    @Test("Sleep manager configuration")
    func testSleepManagerConfig() {
        let sleepManager = SleepManager.shared
        let original = sleepManager.closedLidProtectionEnabled
        sleepManager.closedLidProtectionEnabled = true
        #expect(sleepManager.closedLidProtectionEnabled == true)
        sleepManager.closedLidProtectionEnabled = original
    }

    @Test("LidSleepHelper sudoers validation and script generation")
    func testLidSleepHelperSecurity() throws {
        #expect(LidSleepHelper.isValidUserName("malcolm") == true)
        #expect(LidSleepHelper.isValidUserName("user_1.test-a") == true)
        #expect(LidSleepHelper.isValidUserName("-bad") == false)
        #expect(LidSleepHelper.isValidUserName(".bad") == false)
        #expect(LidSleepHelper.isValidUserName("bad user") == false)
        #expect(LidSleepHelper.isValidUserName("root\nALL=(ALL) NOPASSWD: ALL") == false)

        let rule = try LidSleepHelper.sudoersContent(user: "malcolm")
        #expect(rule.contains("malcolm ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"))

        let install = try LidSleepHelper.installScript(user: "malcolm")
        #expect(install.contains("/usr/sbin/visudo -cf"))
        #expect(install.contains("/etc/sudoers.d/tjuv"))

        let watchdog = LidSleepHelper.watchdogScript(appPID: 12345, executablePath: "/Applications/Tjuv.app/Contents/MacOS/Tjuv")
        #expect(watchdog.contains("12345"))
        #expect(watchdog.contains("/usr/bin/pmset -a disablesleep 0"))
    }

    @Test("LidLockState transitions and screen lock availability")
    func testLidLockState() {
        var state: LidLockState = .open
        #expect(state.shouldLock(isEnabled: true, isArmed: true, isLidClosed: true, lidSleepDisabledByUs: true, hasExternalDisplay: false) == true)
        #expect(state.shouldLock(isEnabled: true, isArmed: true, isLidClosed: true, lidSleepDisabledByUs: true, hasExternalDisplay: true) == false)
        #expect(state.shouldLock(isEnabled: true, isArmed: false, isLidClosed: true, lidSleepDisabledByUs: true, hasExternalDisplay: false) == false)

        state = state.next(isLidClosed: true, locked: true)
        #expect(state == .closedHandled)
        #expect(state.shouldLock(isEnabled: true, isArmed: true, isLidClosed: true, lidSleepDisabledByUs: true, hasExternalDisplay: false) == false)

        state = state.next(isLidClosed: false, locked: false)
        #expect(state == .open)
        #expect(ScreenLocker.isAvailable == true)
    }

    @Test("FindMyDetector status reading")
    func testFindMyDetector() {
        let status = FindMyDetector.currentStatus
        #expect(status == .enabled || status == .disabled)
        #expect(!status.menuTitle.isEmpty)
        #expect(!status.shortSummary.isEmpty)

        #expect(FindMyDetector.status(systemPlistEnabled: true, mobileMeEnabled: false, nvramEnabled: false) == .enabled)
        #expect(FindMyDetector.status(systemPlistEnabled: false, mobileMeEnabled: true, nvramEnabled: false) == .enabled)
        #expect(FindMyDetector.status(systemPlistEnabled: false, mobileMeEnabled: false, nvramEnabled: true) == .enabled)
        #expect(FindMyDetector.status(systemPlistEnabled: false, mobileMeEnabled: false, nvramEnabled: false) == .disabled)

        let accounts: [[String: Any]] = [
            ["Services": [["Name": "FIND_MY_MAC", "Enabled": true]]]
        ]
        #expect(FindMyDetector.isMobileMeFindMyEnabled(accounts: accounts) == true)
    }

    @Test("AppVersion comparison and LatestRelease decoding")
    func testUpdateCheckLogic() throws {
        let v100 = AppVersion("v1.0.0")
        let v110 = AppVersion("1.1.0")
        let v1100 = AppVersion("1.10.0")
        #expect(v100 != nil && v110 != nil && v1100 != nil)
        #expect(v100! < v110!)
        #expect(v110! < v1100!)
        #expect(AppVersion("1.2") == AppVersion("1.2.0"))
        #expect(AppVersion("1.0.0-beta") == nil)

        let json = """
        {"tag_name": "v1.2.0", "html_url": "https://github.com/mj0lken/tjuv/releases/tag/v1.2.0"}
        """.data(using: .utf8)!
        let release = try JSONDecoder().decode(LatestRelease.self, from: json)
        #expect(release.version == AppVersion("1.2.0"))
        #expect(UpdateCheck.availableUpdate(current: v100, latest: release) == release)
        #expect(UpdateCheck.availableUpdate(current: v1100, latest: release) == nil)
    }

    @Test("PrivacyRedactor and GitHubIssueLink")
    func testPrivacyRedactor() {
        let redactor = PrivacyRedactor(
            homeDirectory: "/Users/alice",
            userName: "alice",
            fullName: "Alice Example",
            hostName: "Alices-MacBook-Pro.local"
        )
        let redacted = redactor.redact("Error in /Users/alice/Projects on Alices-MacBook-Pro by alice")
        #expect(redacted == "Error in ~/Projects on <host> by <user>")

        let url = GitHubIssueLink.url(title: "Test Bug", body: "Hello + World & Friends")
        #expect(url.host == "github.com")
        #expect(url.path == "/mj0lken/tjuv/issues/new")
    }

    @Test("Power & charger detection")
    func testPowerDetection() {
        let summary = SystemTriggers.shared.powerStatusSummary
        #expect(!summary.isEmpty)

        let coordinator = AlarmCoordinator.shared
        let origRequire = coordinator.requireChargerToArm
        coordinator.requireChargerToArm = true
        #expect(coordinator.requireChargerToArm == true)
        coordinator.requireChargerToArm = origRequire
    }

    @Test("PowerButtonTracker press, hold, release, and initial-hold ignore state machine")
    func testPowerButtonTracker() {
        var tracker = PowerButtonTracker(holdDurationThreshold: 1.0)
        tracker.reset(isCurrentlyDown: false, currentEnqueueCount: 100)

        // Quiet polls -> .none
        #expect(tracker.update(isCurrentlyDown: false, currentEnqueueCount: 100, now: 10.0) == .none)

        // First press at t=11.0 -> .pressed immediately
        #expect(tracker.update(isCurrentlyDown: true, currentEnqueueCount: 101, now: 11.0) == .pressed)

        // Held for 0.5s (t=11.5) -> .none (not yet 1.0s)
        #expect(tracker.update(isCurrentlyDown: true, currentEnqueueCount: 101, now: 11.5) == .none)

        // Released at t=11.6 (enqueueCount increments to 102 on release) -> .none (must not double-beep on release)
        #expect(tracker.update(isCurrentlyDown: false, currentEnqueueCount: 102, now: 11.6) == .none)

        // Ultra-fast sub-poll tap between t=11.6 and t=11.64 (enqueueCount jumps 102 -> 104 while isCurrentlyDown is false)
        #expect(tracker.update(isCurrentlyDown: false, currentEnqueueCount: 104, now: 11.64) == .pressed)
        #expect(tracker.update(isCurrentlyDown: false, currentEnqueueCount: 104, now: 11.68) == .none)

        // Press and hold >= 1.0s -> .pressed on down, .held at 1.0s, and no duplicate .held while still held
        #expect(tracker.update(isCurrentlyDown: true, currentEnqueueCount: 105, now: 20.0) == .pressed)
        #expect(tracker.update(isCurrentlyDown: true, currentEnqueueCount: 105, now: 20.9) == .none)
        #expect(tracker.update(isCurrentlyDown: true, currentEnqueueCount: 105, now: 21.0) == .held)
        #expect(tracker.update(isCurrentlyDown: true, currentEnqueueCount: 105, now: 21.5) == .none)
        #expect(tracker.update(isCurrentlyDown: false, currentEnqueueCount: 106, now: 22.0) == .none)

        // If button is already held when arming (e.g. user pressed power button to lock screen), ignore until released
        tracker.reset(isCurrentlyDown: true, currentEnqueueCount: 200)
        #expect(tracker.update(isCurrentlyDown: true, currentEnqueueCount: 200, now: 30.0) == .none)
        #expect(tracker.update(isCurrentlyDown: true, currentEnqueueCount: 200, now: 32.0) == .none)
        #expect(tracker.update(isCurrentlyDown: false, currentEnqueueCount: 201, now: 32.1) == .none)
        // Next press after release triggers .pressed normally
        #expect(tracker.update(isCurrentlyDown: true, currentEnqueueCount: 202, now: 33.0) == .pressed)

        // Works even when child EnqueueEventCount is unavailable (nil)
        tracker.reset(isCurrentlyDown: false, currentEnqueueCount: nil)
        #expect(tracker.update(isCurrentlyDown: true, currentEnqueueCount: nil, now: 40.0) == .pressed)
        #expect(tracker.update(isCurrentlyDown: true, currentEnqueueCount: nil, now: 41.0) == .held)
        #expect(tracker.update(isCurrentlyDown: false, currentEnqueueCount: nil, now: 41.2) == .none)
    }

    @Test("SystemTriggers power button hardware state query")
    func testPowerButtonHardwareQuery() {
        let triggers = SystemTriggers.shared
        let orig = triggers.triggerOnPowerButton
        triggers.triggerOnPowerButton = true
        #expect(triggers.triggerOnPowerButton == true)
        triggers.triggerOnPowerButton = orig

        let state = triggers.readPowerButtonHardwareState()
        if triggers.isPowerButtonHardwareAvailable {
            #expect(state.isDown == false || state.isDown == true)
        } else {
            #expect(state.isDown == false)
            #expect(state.enqueueCount == nil)
        }
    }
}
