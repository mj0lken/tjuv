import AppKit
import Foundation

final class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!

    private var flashTimer: Timer?

    // Menu items that need dynamic updating
    private var updateItem: NSMenuItem!
    private var statusHeaderItem: NSMenuItem!
    private var armToggleItem: NSMenuItem!
    private var findMyItem: NSMenuItem!
    private var liveMeterItem: NSMenuItem!
    private var closedLidItem: NSMenuItem!
    private var requireChargerItem: NSMenuItem!
    private var sudoHelperItem: NSMenuItem!
    private var removeSudoHelperItem: NSMenuItem!
    private var speakerStatusItem: NSMenuItem!
    private var powerStatusItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!

    override init() {
        super.init()
        setupStatusBar()
        observeCoordinator()
    }

    // MARK: - Setup

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()
        menu.delegate = self

        updateIcon(for: AlarmCoordinator.shared.state)
        buildMenu()
        statusItem.menu = menu
    }

    private func observeCoordinator() {
        AlarmCoordinator.shared.onStateChanged = { [weak self] state in
            DispatchQueue.main.async {
                self?.updateIcon(for: state)
                self?.updateMenuTitles(for: state)
            }
        }
    }

    // MARK: - Icon Updating

    private func updateIcon(for state: AlarmState) {
        guard let button = statusItem.button else { return }

        flashTimer?.invalidate()
        flashTimer = nil
        button.title = ""

        switch state {
        case .disarmed:
            button.image = NSImage(systemSymbolName: "shield", accessibilityDescription: "Tjuv Disarmed")
            button.contentTintColor = nil

        case .arming(let remaining):
            button.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Tjuv Arming")
            button.title = " \(remaining)s"
            button.contentTintColor = .systemOrange

        case .armed:
            button.image = NSImage(systemSymbolName: "shield.fill", accessibilityDescription: "Tjuv Armed")
            button.contentTintColor = .systemGreen

        case .countdown(let remaining, _):
            button.image = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: "Tjuv Triggered")
            button.title = " \(remaining)s"
            button.contentTintColor = .systemOrange
            startFlashingIcon(symbol1: "bell.badge.fill", symbol2: "bell.fill", color: .systemOrange)

        case .alarmActive:
            button.image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: "Tjuv Alarm Blaring")
            button.title = " ALARM"
            button.contentTintColor = .systemRed
            startFlashingIcon(symbol1: "speaker.wave.3.fill", symbol2: "bell.fill", color: .systemRed)
        }
    }

    private func startFlashingIcon(symbol1: String, symbol2: String, color: NSColor) {
        var toggle = false
        flashTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let button = self?.statusItem.button else { return }
            toggle.toggle()
            button.image = NSImage(systemSymbolName: toggle ? symbol1 : symbol2, accessibilityDescription: "Alarm")
            button.contentTintColor = toggle ? color : .labelColor
        }
    }

    // MARK: - Menu Construction

    private func buildMenu() {
        menu.removeAllItems()

        // 0. Update notice (hidden unless a newer release is available)
        updateItem = NSMenuItem(title: "", action: #selector(openUpdateAction), keyEquivalent: "")
        updateItem.target = self
        updateItem.isHidden = true
        menu.addItem(updateItem)

        // 1. Status Header
        statusHeaderItem = NSMenuItem(title: "Status: Disarmed", action: nil, keyEquivalent: "")
        statusHeaderItem.isEnabled = false
        menu.addItem(statusHeaderItem)

        // 2. Arm / Disarm Primary Action
        armToggleItem = NSMenuItem(title: "Arm Alarm", action: #selector(toggleArmAction), keyEquivalent: "a")
        armToggleItem.target = self
        menu.addItem(armToggleItem)

        // 3. Find My Mac (AirTag Beacon) Status
        findMyItem = NSMenuItem(
            title: FindMyDetector.currentStatus.menuTitle,
            action: #selector(openFindMySettingsAction),
            keyEquivalent: ""
        )
        findMyItem.target = self
        menu.addItem(findMyItem)

        menu.addItem(NSMenuItem.separator())

        // 4. Closed Lid & Power Guard Mode
        closedLidItem = NSMenuItem(title: "Protect When Lid Closed", action: #selector(toggleClosedLidAction), keyEquivalent: "")
        closedLidItem.target = self
        closedLidItem.state = SleepManager.shared.closedLidProtectionEnabled ? .on : .off
        menu.addItem(closedLidItem)

        requireChargerItem = NSMenuItem(title: "Require Charger Connected to Arm", action: #selector(toggleRequireChargerAction), keyEquivalent: "")
        requireChargerItem.target = self
        requireChargerItem.state = AlarmCoordinator.shared.requireChargerToArm ? .on : .off
        menu.addItem(requireChargerItem)

        sudoHelperItem = NSMenuItem(title: "Set Up Closed-Lid Mode…", action: #selector(setupPasswordlessSudoAction), keyEquivalent: "")
        sudoHelperItem.target = self
        menu.addItem(sudoHelperItem)

        removeSudoHelperItem = NSMenuItem(title: "Remove Closed-Lid Setup…", action: #selector(removePasswordlessSudoAction), keyEquivalent: "")
        removeSudoHelperItem.target = self
        menu.addItem(removeSudoHelperItem)

        menu.addItem(NSMenuItem.separator())

        // 5. Sensitivity Submenu
        let sensitivityMenu = NSMenu()
        for s in MotionSensitivity.allCases {
            let item = NSMenuItem(title: s.rawValue, action: #selector(changeSensitivityAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s
            item.state = (MotionDetector.shared.sensitivity == s) ? .on : .off
            sensitivityMenu.addItem(item)
        }
        let sensParentItem = NSMenuItem(title: "Motion Sensitivity", action: nil, keyEquivalent: "")
        sensParentItem.submenu = sensitivityMenu
        menu.addItem(sensParentItem)

        // 6. Arming Delay Submenu
        let delayMenu = NSMenu()
        for sec in [0, 5, 10, 15] {
            let title = sec == 0 ? "Instant (0 seconds)" : "\(sec) seconds"
            let item = NSMenuItem(title: title, action: #selector(changeArmingDelayAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = sec
            item.state = (AlarmCoordinator.shared.armingDelaySeconds == sec) ? .on : .off
            delayMenu.addItem(item)
        }
        let delayParentItem = NSMenuItem(title: "Arming Delay", action: nil, keyEquivalent: "")
        delayParentItem.submenu = delayMenu
        menu.addItem(delayParentItem)

        // 7. Countdown Duration Submenu
        let countdownMenu = NSMenu()
        for sec in [3, 5, 10] {
            let item = NSMenuItem(title: "\(sec) seconds", action: #selector(changeCountdownDurationAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = sec
            item.state = (AlarmCoordinator.shared.countdownDurationSeconds == sec) ? .on : .off
            countdownMenu.addItem(item)
        }
        let countdownParentItem = NSMenuItem(title: "Countdown Duration", action: nil, keyEquivalent: "")
        countdownParentItem.submenu = countdownMenu
        menu.addItem(countdownParentItem)

        // 8. Auxiliary Triggers Submenu
        let triggersMenu = NSMenu()

        let powerItem = NSMenuItem(title: "Trigger on Power Unplugged", action: #selector(togglePowerTriggerAction), keyEquivalent: "")
        powerItem.target = self
        powerItem.state = SystemTriggers.shared.triggerOnPowerUnplugged ? .on : .off
        triggersMenu.addItem(powerItem)

        let lidItem = NSMenuItem(title: "Trigger on Lid Opened", action: #selector(toggleLidTriggerAction), keyEquivalent: "")
        lidItem.target = self
        lidItem.state = SystemTriggers.shared.triggerOnLidOpened ? .on : .off
        triggersMenu.addItem(lidItem)

        let triggersParentItem = NSMenuItem(title: "Auxiliary Triggers", action: nil, keyEquivalent: "")
        triggersParentItem.submenu = triggersMenu
        menu.addItem(triggersParentItem)

        // 9. Security & Stolen Mode Submenu
        let securityMenu = NSMenu()
        let touchIDItem = NSMenuItem(title: "Require Touch ID to Disarm", action: #selector(toggleTouchIDAction), keyEquivalent: "")
        touchIDItem.target = self
        touchIDItem.state = AuthManager.shared.requireAuthToDisarm ? .on : .off
        securityMenu.addItem(touchIDItem)

        let lockOnTriggerItem = NSMenuItem(title: "Lock Screen Immediately on Trigger", action: #selector(toggleLockOnTriggerAction), keyEquivalent: "")
        lockOnTriggerItem.target = self
        lockOnTriggerItem.isEnabled = ScreenLocker.isAvailable
        lockOnTriggerItem.state = (ScreenLocker.isAvailable && AlarmCoordinator.shared.lockScreenOnTrigger) ? .on : .off
        securityMenu.addItem(lockOnTriggerItem)

        let lockOnLidItem = NSMenuItem(title: "Lock Screen When Lid Closes While Armed", action: #selector(toggleLockOnLidAction), keyEquivalent: "")
        lockOnLidItem.target = self
        lockOnLidItem.isEnabled = ScreenLocker.isAvailable
        lockOnLidItem.state = (ScreenLocker.isAvailable && AlarmCoordinator.shared.lockScreenOnLidClose) ? .on : .off
        securityMenu.addItem(lockOnLidItem)

        securityMenu.addItem(NSMenuItem.separator())

        let findMySettingsItem = NSMenuItem(title: "Open Find My Mac Settings…", action: #selector(openFindMySettingsAction), keyEquivalent: "")
        findMySettingsItem.target = self
        securityMenu.addItem(findMySettingsItem)

        let secParentItem = NSMenuItem(title: "Security & Stolen Mode", action: nil, keyEquivalent: "")
        secParentItem.submenu = securityMenu
        menu.addItem(secParentItem)

        menu.addItem(NSMenuItem.separator())

        // 10. Hardware & Diagnostics
        let diagMenu = NSMenu()

        speakerStatusItem = NSMenuItem(title: "Speaker: Scanning...", action: nil, keyEquivalent: "")
        diagMenu.addItem(speakerStatusItem)

        powerStatusItem = NSMenuItem(title: "Power: Scanning...", action: nil, keyEquivalent: "")
        diagMenu.addItem(powerStatusItem)

        let sensorStatus = MotionDetector.shared.isHardwareAvailable ? "Hardware IMU (AppleSPUHIDDevice)" : "Sensor Unavailable"
        diagMenu.addItem(NSMenuItem(title: "Sensor: \(sensorStatus)", action: nil, keyEquivalent: ""))

        liveMeterItem = NSMenuItem(title: "Live G-force: 1.00 g", action: nil, keyEquivalent: "")
        diagMenu.addItem(liveMeterItem)

        let diagParentItem = NSMenuItem(title: "Hardware Status", action: nil, keyEquivalent: "")
        diagParentItem.submenu = diagMenu
        menu.addItem(diagParentItem)

        // 11. Test Siren
        let testItem = NSMenuItem(title: "Test Siren (1.5s Max Volume)", action: #selector(testSirenAction), keyEquivalent: "")
        testItem.target = self
        menu.addItem(testItem)

        menu.addItem(NSMenuItem.separator())

        // 12. General, Updates & Bug Report
        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLoginAction), keyEquivalent: "")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(launchAtLoginItem)

        let checkUpdatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdatesAction), keyEquivalent: "")
        checkUpdatesItem.target = self
        menu.addItem(checkUpdatesItem)

        let reportBugItem = NSMenuItem(title: "Report a Bug…", action: #selector(reportBugAction), keyEquivalent: "")
        reportBugItem.target = self
        menu.addItem(reportBugItem)

        menu.addItem(NSMenuItem.separator())

        // 13. Quit
        let quitItem = NSMenuItem(title: "Quit Tjuv", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Menu Delegate (Dynamic Refresh)

    func menuWillOpen(_ menu: NSMenu) {
        updateMenuTitles(for: AlarmCoordinator.shared.state)
        updateSpeakerStatus()
        updatePowerStatus()
        updateLiveGForce()
        updateFindMyStatus()
        updateSudoSetupItems()
        updateReleaseBanner()
        requireChargerItem?.state = AlarmCoordinator.shared.requireChargerToArm ? .on : .off
        launchAtLoginItem?.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    private func updateReleaseBanner() {
        if let release = UpdateChecker.shared.availableUpdate {
            if UpdateChecker.shared.isHomebrewInstall {
                updateItem?.title = "⬆️ Tjuv \(release.version) Available (Copy `\(UpdateChecker.homebrewCommand)`)"
            } else {
                updateItem?.title = "⬆️ Tjuv \(release.version) Available (Download Release…)"
            }
            updateItem?.isHidden = false
        } else {
            updateItem?.isHidden = true
        }
    }

    private func updateFindMyStatus() {
        findMyItem?.title = FindMyDetector.currentStatus.menuTitle
    }

    private func updateSudoSetupItems() {
        let installed = SleepManager.shared.hasPasswordlessSudo
        sudoHelperItem?.title = installed ? "Closed-Lid Setup: Installed ✓" : "Set Up Closed-Lid Mode…"
        sudoHelperItem?.isEnabled = !installed
        removeSudoHelperItem?.isHidden = !installed
    }

    private func updatePowerStatus() {
        powerStatusItem?.title = "Power: \(SystemTriggers.shared.powerStatusSummary)"
    }

    private func updateMenuTitles(for state: AlarmState) {
        switch state {
        case .disarmed:
            statusHeaderItem?.title = "Status: Disarmed"
            armToggleItem?.title = "Arm Alarm"
            armToggleItem?.keyEquivalent = "a"
        case .arming(let remaining):
            statusHeaderItem?.title = "Status: Arming in \(remaining)s..."
            armToggleItem?.title = "Cancel Arming"
            armToggleItem?.keyEquivalent = "d"
        case .armed:
            statusHeaderItem?.title = "Status: 🛡️ ARMED & MONITORING"
            armToggleItem?.title = "Disarm Alarm"
            armToggleItem?.keyEquivalent = "d"
        case .countdown(let remaining, let reason):
            statusHeaderItem?.title = "Status: ⚠️ TRIGGERED (\(remaining)s) - \(reason)"
            armToggleItem?.title = "Disarm Alarm Now!"
            armToggleItem?.keyEquivalent = "d"
        case .alarmActive(let reason):
            statusHeaderItem?.title = "Status: 🚨 ALARM ACTIVE - \(reason)"
            armToggleItem?.title = "DISARM ALARM NOW!"
            armToggleItem?.keyEquivalent = "d"
        }
    }

    private func updateSpeakerStatus() {
        if let speakerID = AudioController.shared.findBuiltInSpeakerID() {
            speakerStatusItem?.title = "Speaker: Internal Speaker (ID: \(speakerID))"
        } else {
            speakerStatusItem?.title = "Speaker: Built-in speaker not found!"
        }
    }

    private func updateLiveGForce() {
        let norm = AlarmCoordinator.shared.liveNormG
        let delta = AlarmCoordinator.shared.liveDeltaG
        liveMeterItem?.title = String(format: "Live G: %0.3f g (Δ %0.3f g)", norm, delta)
    }

    // MARK: - Actions

    @objc private func toggleArmAction() {
        let result = AlarmCoordinator.shared.toggleArm()
        if !result.success, let msg = result.message {
            let alert = NSAlert()
            alert.messageText = "Cannot Arm Alarm"
            alert.informativeText = msg
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func openFindMySettingsAction() {
        let status = FindMyDetector.currentStatus
        if status == .enabled {
            let alert = NSAlert()
            alert.messageText = "Find My Mac (AirTag Beacon) is Active"
            alert.informativeText = "Your Mac already has an active Find My Mac token in NVRAM. Because this is an Apple Silicon Mac, its Bluetooth controller broadcasts rotating encrypted P-224 beacons to Apple's Find My network—just like an AirTag—even when offline or asleep.\n\nWhen Tjuv keeps the Mac awake with the lid closed, your Mac also maintains live Wi-Fi positioning."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open iCloud Settings…")
            if alert.runModal() == .alertSecondButtonReturn {
                FindMyDetector.openSystemSettings()
            }
        } else {
            let alert = NSAlert()
            alert.messageText = "Enable Find My Mac (AirTag Mode)"
            alert.informativeText = "Find My Mac is currently turned off on this computer.\n\nTurn on both 'Find My Mac' and 'Find My network' in System Settings › [Your Name] › iCloud › Find My Mac so your MacBook broadcasts encrypted AirTag-style Bluetooth beacons if stolen."
            alert.addButton(withTitle: "Open System Settings…")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                FindMyDetector.openSystemSettings()
            }
        }
    }

    @objc private func toggleRequireChargerAction() {
        AlarmCoordinator.shared.requireChargerToArm.toggle()
        requireChargerItem?.state = AlarmCoordinator.shared.requireChargerToArm ? .on : .off
    }

    @objc private func toggleClosedLidAction() {
        let current = SleepManager.shared.closedLidProtectionEnabled
        SleepManager.shared.closedLidProtectionEnabled = !current
        closedLidItem.state = (!current) ? .on : .off
    }

    @objc private func setupPasswordlessSudoAction() {
        let alert = NSAlert()
        alert.messageText = "Set Up Closed-Lid Mode"
        alert.informativeText = "Closing the lid normally forces macOS to sleep, ignoring standard keep-awake assertions.\n\nTjuv can install a visudo-validated rule at /etc/sudoers.d/tjuv that allows your account to run only 'pmset -a disablesleep 0' and '1' without a password. A watchdog process automatically restores lid sleep if Tjuv ever quits or crashes."
        alert.addButton(withTitle: "Set Up…")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            SleepManager.shared.installPasswordlessHelper { [weak self] success, error in
                self?.updateSudoSetupItems()
                guard !success, error != "Cancelled." else { return }
                let resultAlert = NSAlert()
                resultAlert.messageText = "Closed-Lid Setup Failed"
                resultAlert.informativeText = error ?? "Could not authorize administrative access."
                resultAlert.runModal()
            }
        }
    }

    @objc private func removePasswordlessSudoAction() {
        SleepManager.shared.uninstallPasswordlessHelper { [weak self] success, error in
            self?.updateSudoSetupItems()
            guard !success, error != "Cancelled." else { return }
            let resultAlert = NSAlert()
            resultAlert.messageText = "Couldn't Remove Closed-Lid Setup"
            resultAlert.informativeText = error ?? "Could not remove /etc/sudoers.d/tjuv."
            resultAlert.runModal()
        }
    }

    @objc private func changeSensitivityAction(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? MotionSensitivity else { return }
        MotionDetector.shared.sensitivity = s
        buildMenu()
    }

    @objc private func changeArmingDelayAction(_ sender: NSMenuItem) {
        guard let sec = sender.representedObject as? Int else { return }
        AlarmCoordinator.shared.armingDelaySeconds = sec
        buildMenu()
    }

    @objc private func changeCountdownDurationAction(_ sender: NSMenuItem) {
        guard let sec = sender.representedObject as? Int else { return }
        AlarmCoordinator.shared.countdownDurationSeconds = sec
        buildMenu()
    }

    @objc private func togglePowerTriggerAction() {
        SystemTriggers.shared.triggerOnPowerUnplugged.toggle()
        buildMenu()
    }

    @objc private func toggleLidTriggerAction() {
        SystemTriggers.shared.triggerOnLidOpened.toggle()
        buildMenu()
    }

    @objc private func toggleTouchIDAction() {
        AuthManager.shared.requireAuthToDisarm.toggle()
        buildMenu()
    }

    @objc private func toggleLockOnTriggerAction() {
        AlarmCoordinator.shared.lockScreenOnTrigger.toggle()
        buildMenu()
    }

    @objc private func toggleLockOnLidAction() {
        AlarmCoordinator.shared.lockScreenOnLidClose.toggle()
        buildMenu()
    }

    @objc private func toggleLaunchAtLoginAction() {
        let target = !LaunchAtLogin.isEnabled
        if let err = LaunchAtLogin.setEnabled(target) {
            let alert = NSAlert()
            alert.messageText = "Couldn't Change Launch at Login"
            alert.informativeText = err
            alert.runModal()
        }
        launchAtLoginItem?.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    @objc private func openUpdateAction() {
        guard let release = UpdateChecker.shared.availableUpdate else { return }
        if UpdateChecker.shared.isHomebrewInstall {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(UpdateChecker.homebrewCommand, forType: .string)
        } else {
            NSWorkspace.shared.open(release.pageURL)
        }
    }

    @objc private func checkForUpdatesAction() {
        UpdateChecker.shared.checkNow { result in
            let alert = NSAlert()
            switch result {
            case .success(let release):
                if let release {
                    alert.messageText = "Tjuv \(release.version) is Available"
                    alert.informativeText = UpdateChecker.shared.isHomebrewInstall
                        ? "Run '\(UpdateChecker.homebrewCommand)' in Terminal to update."
                        : "Download the latest version from GitHub Releases."
                    alert.addButton(withTitle: UpdateChecker.shared.isHomebrewInstall ? "Copy Command" : "Open Release Page…")
                    alert.addButton(withTitle: "Later")
                    if alert.runModal() == .alertFirstButtonReturn {
                        if UpdateChecker.shared.isHomebrewInstall {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(UpdateChecker.homebrewCommand, forType: .string)
                        } else {
                            NSWorkspace.shared.open(release.pageURL)
                        }
                    }
                } else {
                    let ver = UpdateChecker.shared.currentVersion?.description ?? "1.0.0"
                    alert.messageText = "Tjuv \(ver) is Up to Date"
                    alert.informativeText = "You're running the latest release."
                    alert.runModal()
                }
            case .failure(let error):
                alert.messageText = "Update Check Failed"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    @objc private func reportBugAction() {
        GitHubIssueLink.openNewIssue()
    }

    @objc private func testSirenAction() {
        AudioController.shared.testSiren()
    }

    @objc private func quitAction() {
        AlarmCoordinator.shared.forceDisarm()
        NSApplication.shared.terminate(nil)
    }
}
