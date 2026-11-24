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

@Suite("Self-update")
struct SelfUpdateTests {
    @Test("Release decoding picks the app zip, its digest and checksum file")
    func decodesAsset() throws {
        let digest = String(repeating: "ab", count: 32)
        let json = """
        {"tag_name":"v1.2.0","html_url":"https://github.com/mj0lken/tjuv/releases/tag/v1.2.0","assets":[
          {"name":"tjuv-1.2.0-arm64.zip.sha256","browser_download_url":"https://github.com/mj0lken/tjuv/releases/download/v1.2.0/tjuv-1.2.0-arm64.zip.sha256","digest":null},
          {"name":"tjuv-1.2.0-arm64.zip","browser_download_url":"https://github.com/mj0lken/tjuv/releases/download/v1.2.0/tjuv-1.2.0-arm64.zip","digest":"sha256:\(digest)"}
        ]}
        """.data(using: .utf8)!
        let release = try JSONDecoder().decode(LatestRelease.self, from: json)
        #expect(release.asset?.downloadURL.lastPathComponent == "tjuv-1.2.0-arm64.zip")
        #expect(release.asset?.sha256 == digest)
        #expect(release.asset?.checksumURL?.lastPathComponent == "tjuv-1.2.0-arm64.zip.sha256")
    }

    @Test("Missing digest falls back to trusted .sha256 asset and rejects untrusted checksum URLs")
    func decodesChecksumFallbackAndRejectsUntrustedChecksum() throws {
        let validFallbackJSON = """
        {"tag_name":"v1.2.0","html_url":"https://github.com/mj0lken/tjuv/releases/tag/v1.2.0","assets":[
          {"name":"tjuv-1.2.0-arm64.zip","browser_download_url":"https://github.com/mj0lken/tjuv/releases/download/v1.2.0/tjuv-1.2.0-arm64.zip","digest":null},
          {"name":"tjuv-1.2.0-arm64.zip.sha256","browser_download_url":"https://github.com/mj0lken/tjuv/releases/download/v1.2.0/tjuv-1.2.0-arm64.zip.sha256","digest":null}
        ]}
        """.data(using: .utf8)!
        let fallbackRelease = try JSONDecoder().decode(LatestRelease.self, from: validFallbackJSON)
        #expect(fallbackRelease.asset?.sha256 == nil)
        #expect(fallbackRelease.asset?.checksumURL?.lastPathComponent == "tjuv-1.2.0-arm64.zip.sha256")

        let untrustedChecksumJSON = """
        {"tag_name":"v1.2.0","html_url":"https://github.com/mj0lken/tjuv/releases/tag/v1.2.0","assets":[
          {"name":"tjuv-1.2.0-arm64.zip","browser_download_url":"https://github.com/mj0lken/tjuv/releases/download/v1.2.0/tjuv-1.2.0-arm64.zip","digest":"sha256:not-hex"},
          {"name":"tjuv-1.2.0-arm64.zip.sha256","browser_download_url":"https://evil.example/tjuv-1.2.0-arm64.zip.sha256","digest":null}
        ]}
        """.data(using: .utf8)!
        let untrustedRelease = try JSONDecoder().decode(LatestRelease.self, from: untrustedChecksumJSON)
        #expect(untrustedRelease.asset != nil)
        #expect(untrustedRelease.asset?.sha256 == nil)
        #expect(untrustedRelease.asset?.checksumURL == nil)
    }

    @Test("Downloads from anywhere but this repo's releases (including path traversal) are ignored")
    func rejectsForeignDownloads() throws {
        let badURLs = [
            "https://evil.example/tjuv-1.2.0-arm64.zip",
            "https://github.com/other/tjuv/releases/download/v1.2.0/tjuv-1.2.0-arm64.zip",
            "https://github.com/mj0lken/tjuv/releases/download/v1.2.0/../../other/repo/tjuv-1.2.0-arm64.zip",
            "https://github.com/mj0lken/tjuv/releases/download/v1.2.0/%2e%2e/tjuv-1.2.0-arm64.zip",
            "http://github.com/mj0lken/tjuv/releases/download/v1.2.0/tjuv-1.2.0-arm64.zip",
        ]
        for bad in badURLs {
            let json = """
            {"tag_name":"v1.2.0","html_url":"https://github.com/mj0lken/tjuv/releases/tag/v1.2.0","assets":[
              {"name":"tjuv-1.2.0-arm64.zip","browser_download_url":"\(bad)","digest":"sha256:00"}
            ]}
            """.data(using: .utf8)!
            let release = try JSONDecoder().decode(LatestRelease.self, from: json)
            #expect(release.asset == nil)
        }
    }

    @Test("30-minute check cadence handles boundary, nil, and clock skew")
    func checkCadence() {
        #expect(UpdateCheck.interval == 30 * 60)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(UpdateCheck.isDue(lastCheck: nil, now: now) == true)
        #expect(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-(30 * 60 - 1)), now: now) == false)
        #expect(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-(30 * 60)), now: now) == true)
        #expect(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(60), now: now) == true)
    }

    @Test("Only restarts for an update when protection isn't active across all AlarmState cases")
    func safeStates() {
        #expect(UpdateInstaller.isSafeToRestart(.disarmed) == true)
        #expect(UpdateInstaller.isSafeToRestart(.standby) == true)
        #expect(UpdateInstaller.isSafeToRestart(.arming(remainingSeconds: 3)) == false)
        #expect(UpdateInstaller.isSafeToRestart(.armed) == false)
        #expect(UpdateInstaller.isSafeToRestart(.gracePeriod(remainingSeconds: 5)) == false)
        #expect(UpdateInstaller.isSafeToRestart(.countdown(remainingSeconds: 5, reason: "Motion")) == false)
        #expect(UpdateInstaller.isSafeToRestart(.alarmActive(reason: "Motion")) == false)
    }

    @Test("Checksum file parsing normalizes valid SHA-256 and rejects malformed text")
    func parsesChecksumFiles() {
        let lower = String(repeating: "0123456789abcdef", count: 4)
        let upper = lower.uppercased()
        #expect(UpdateInstaller.parseChecksumFile("\(lower)  tjuv-1.2.0-arm64.zip\n") == lower)
        #expect(UpdateInstaller.parseChecksumFile("  \(upper)  tjuv-1.2.0-arm64.zip  ") == lower)
        #expect(UpdateInstaller.parseChecksumFile("\(lower)\n") == lower)
        #expect(UpdateInstaller.parseChecksumFile("") == nil)
        #expect(UpdateInstaller.parseChecksumFile("abcd  tjuv-1.2.0-arm64.zip") == nil)
        #expect(UpdateInstaller.parseChecksumFile(String(repeating: "z", count: 64) + "  tjuv.zip") == nil)
        #expect(UpdateInstaller.parseChecksumFile("<html>Not Found</html>") == nil)
    }

    @Test("Self-update eligibility allows writable .app bundles including Homebrew and blocks non-writable or dev builds")
    func canSelfUpdateMatrix() {
        let appURL = URL(fileURLWithPath: "/Applications/Tjuv.app")
        let devBinary = URL(fileURLWithPath: "/Users/dev/Tjuv/.build/debug/Tjuv")

        #expect(UpdateInstaller.canSelfUpdate(bundleURL: appURL, bundleIdentifier: "com.mj0lken.tjuv", isWritable: true, isHomebrewInstall: false) == true)
        #expect(UpdateInstaller.canSelfUpdate(bundleURL: appURL, bundleIdentifier: "com.mj0lken.tjuv", isWritable: true, isHomebrewInstall: true) == true)
        #expect(UpdateInstaller.canSelfUpdate(bundleURL: appURL, bundleIdentifier: "com.mj0lken.tjuv", isWritable: false, isHomebrewInstall: false) == false)
        #expect(UpdateInstaller.canSelfUpdate(bundleURL: appURL, bundleIdentifier: "com.mj0lken.tjuv", isWritable: false, isHomebrewInstall: true) == false)
        #expect(UpdateInstaller.canSelfUpdate(bundleURL: devBinary, bundleIdentifier: "com.mj0lken.tjuv", isWritable: true, isHomebrewInstall: false) == false)
        #expect(UpdateInstaller.canSelfUpdate(bundleURL: appURL, bundleIdentifier: "com.example.other", isWritable: true, isHomebrewInstall: false) == false)
        #expect(UpdateInstaller.canSelfUpdate(bundleURL: appURL, bundleIdentifier: nil, isWritable: true, isHomebrewInstall: false) == false)
        let translocated = URL(fileURLWithPath: "/private/var/folders/xx/AppTranslocation/UUID/d/Tjuv.app")
        #expect(UpdateInstaller.canSelfUpdate(bundleURL: translocated, bundleIdentifier: "com.mj0lken.tjuv", isWritable: true, isHomebrewInstall: false) == false)
    }

    @Test("Homebrew install detection ignores local builds even if a Caskroom directory exists")
    func homebrewInstallDetection() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("tjuv-cask-test-\(UUID().uuidString)", isDirectory: true)
        let caskroom = tempRoot.appendingPathComponent("Caskroom/tjuv", isDirectory: true)
        let metadata = caskroom.appendingPathComponent(".metadata", isDirectory: true)
        let caskApp = caskroom.appendingPathComponent("1.1.0/Tjuv.app", isDirectory: true)
        let localBuild = tempRoot.appendingPathComponent("Projects/Tjuv/build/Tjuv.app", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caskApp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localBuild, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        #expect(UpdateCheck.detectHomebrewInstall(bundleURL: localBuild, caskroomPaths: [caskroom.path]) == false)
        #expect(UpdateCheck.detectHomebrewInstall(bundleURL: caskApp, caskroomPaths: [caskroom.path]) == true)
    }

    @Test("ETag 304 caching preserves available update and persists asset metadata across relaunch")
    @MainActor
    func etagCachingAndAssetPersistence() async throws {
        let suiteName = "com.mj0lken.tjuv.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let digest = String(repeating: "cd", count: 32)
        let payload = """
        {"tag_name":"v1.3.0","html_url":"https://github.com/mj0lken/tjuv/releases/tag/v1.3.0","assets":[
          {"name":"tjuv-1.3.0-arm64.zip","browser_download_url":"https://github.com/mj0lken/tjuv/releases/download/v1.3.0/tjuv-1.3.0-arm64.zip","digest":"sha256:\(digest)"},
          {"name":"tjuv-1.3.0-arm64.zip.sha256","browser_download_url":"https://github.com/mj0lken/tjuv/releases/download/v1.3.0/tjuv-1.3.0-arm64.zip.sha256","digest":null}
        ]}
        """.data(using: .utf8)!

        final class RequestBox: @unchecked Sendable {
            var count = 0
            var lastIfNoneMatch: String?
        }
        let box = RequestBox()
        let endpoint = URL(string: "https://api.github.com/repos/mj0lken/tjuv/releases/latest")!

        let checker = UpdateChecker(
            defaults: defaults,
            currentVersion: AppVersion("1.2.0"),
            isHomebrewInstall: false,
            fetch: { request in
                box.count += 1
                box.lastIfNoneMatch = request.value(forHTTPHeaderField: "If-None-Match")
                if box.count == 1 {
                    let resp = HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"etag-v130\""])!
                    return (payload, resp)
                } else {
                    let resp = HTTPURLResponse(url: endpoint, statusCode: 304, httpVersion: nil, headerFields: nil)!
                    return (Data(), resp)
                }
            }
        )

        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await checker.performCheck(now: t1)
        #expect(box.lastIfNoneMatch == nil)
        #expect(checker.status == .idle)
        #expect(checker.lastCheck == t1)
        #expect(checker.availableUpdate?.version == AppVersion("1.3.0"))
        #expect(checker.availableUpdate?.asset?.sha256 == digest)

        // Second check sends If-None-Match and handles 304 Not Modified
        let t2 = t1.addingTimeInterval(35 * 60)
        _ = await checker.performCheck(now: t2)
        #expect(box.lastIfNoneMatch == "\"etag-v130\"")
        #expect(checker.status == .idle)
        #expect(checker.lastCheck == t2)
        #expect(checker.availableUpdate?.version == AppVersion("1.3.0"))
        #expect(checker.availableUpdate?.asset?.sha256 == digest)

        // Simulated relaunch restores cached release WITH full asset metadata
        let relaunched = UpdateChecker(defaults: defaults, currentVersion: AppVersion("1.2.0"), isHomebrewInstall: false)
        #expect(relaunched.availableUpdate?.version == AppVersion("1.3.0"))
        #expect(relaunched.availableUpdate?.asset?.downloadURL.lastPathComponent == "tjuv-1.3.0-arm64.zip")
        #expect(relaunched.availableUpdate?.asset?.sha256 == digest)
        #expect(relaunched.availableUpdate?.asset?.checksumURL?.lastPathComponent == "tjuv-1.3.0-arm64.zip.sha256")

        // When already on 1.3.0, a 304 marks status as .upToDate with nil availableUpdate
        let upToDateChecker = UpdateChecker(
            defaults: defaults,
            currentVersion: AppVersion("1.3.0"),
            isHomebrewInstall: false,
            fetch: { request in
                #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"etag-v130\"")
                let resp = HTTPURLResponse(url: endpoint, statusCode: 304, httpVersion: nil, headerFields: nil)!
                return (Data(), resp)
            }
        )
        _ = await upToDateChecker.performCheck(now: t2.addingTimeInterval(60))
        #expect(upToDateChecker.availableUpdate == nil)
        #expect(upToDateChecker.status == .upToDate)
    }

    @Test("SHA-256 of a file")
    func hashesFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try UpdateInstaller.sha256(of: url) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("Install script ignores HUP, waits on PID, guards rollback on backup existence, and uses ditto and open")
    func installScriptSanity() {
        let script = UpdateInstaller.installScript()
        #expect(script.hasPrefix("#!/usr/bin/env bash"))
        #expect(script.contains("trap '' HUP"))
        #expect(script.contains(#"kill -0 "$PID""#))
        #expect(script.contains(#"if [[ -e "$BACKUP" ]]; then"#))
        #expect(script.contains(#"/usr/bin/ditto "$NEW_APP" "$TARGET_APP""#))
        #expect(script.contains(#"/usr/bin/open "$TARGET_APP""#))
    }
}
