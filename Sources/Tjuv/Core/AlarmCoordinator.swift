import Foundation
import AppKit

enum AlarmState: Equatable {
    /// Master switch is OFF.
    case disarmed
    /// Master switch is ON while the Mac is unlocked (active use). Automatically arms on screen lock or lid close.
    case standby
    /// Settling countdown before entering `.armed`.
    case arming(remainingSeconds: Int)
    /// Actively guarding while the Mac is locked or the lid is closed.
    case armed
    /// 3-second grace window (two short warning beeps) to put the laptop down still or plug power back in.
    case gracePeriod(remainingSeconds: Int)
    /// Polite countdown before the 100% siren blasts.
    case countdown(remainingSeconds: Int, reason: String)
    /// 100% built-in speaker siren active.
    case alarmActive(reason: String)

    var isEnabled: Bool {
        self != .disarmed
    }
}

final class AlarmCoordinator: ObservableObject {
    static let shared = AlarmCoordinator()

    @Published private(set) var state: AlarmState = .disarmed
    @Published private(set) var liveDeltaG: Double = 0.0
    @Published private(set) var liveNormG: Double = 1.0

    var onStateChanged: ((AlarmState) -> Void)?

    // Master switch persisted across launches (default: true, just like thumbs-out)
    var isMasterEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "isTjuvEnabled") == nil { return true }
            return UserDefaults.standard.bool(forKey: "isTjuvEnabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "isTjuvEnabled")
        }
    }

    // User Settings
    var armingDelaySeconds: Int {
        get { UserDefaults.standard.object(forKey: "armingDelaySeconds") as? Int ?? 3 }
        set { UserDefaults.standard.set(newValue, forKey: "armingDelaySeconds") }
    }

    var countdownDurationSeconds: Int {
        get { UserDefaults.standard.object(forKey: "countdownDurationSeconds") as? Int ?? 5 }
        set { UserDefaults.standard.set(newValue, forKey: "countdownDurationSeconds") }
    }

    var requireChargerToArm: Bool {
        get { UserDefaults.standard.bool(forKey: "requireChargerToArm") }
        set { UserDefaults.standard.set(newValue, forKey: "requireChargerToArm") }
    }

    var lockScreenOnTrigger: Bool {
        get {
            if UserDefaults.standard.object(forKey: "lockScreenOnTrigger") == nil { return true }
            return UserDefaults.standard.bool(forKey: "lockScreenOnTrigger")
        }
        set { UserDefaults.standard.set(newValue, forKey: "lockScreenOnTrigger") }
    }

    var lockScreenOnLidClose: Bool {
        get {
            if UserDefaults.standard.object(forKey: "lockScreenOnLidClose") == nil { return true }
            return UserDefaults.standard.bool(forKey: "lockScreenOnLidClose")
        }
        set { UserDefaults.standard.set(newValue, forKey: "lockScreenOnLidClose") }
    }

    let gracePeriodSeconds: Int = 3
    private var lidLockState: LidLockState = .unknown
    private var armingTimer: Timer?
    private var graceTimer: Timer?
    private var countdownTimer: Timer?
    private var batteryCheckTimer: Timer?

    init() {
        setupSensorCallbacks()
    }

    /// Starts Tjuv in `.standby` if the master switch is enabled.
    func start() {
        if isMasterEnabled {
            enterStandby()
        } else {
            transition(to: .disarmed)
        }
    }

    // MARK: - Setup Callbacks

    private func setupSensorCallbacks() {
        // Accelerometer motion callback (starts 3-second grace period with two short beeps)
        MotionDetector.shared.onMotionDetected = { [weak self] in
            self?.handleMotionGracePeriod()
        }

        MotionDetector.shared.onMotionSample = { [weak self] deltaG, normG in
            self?.liveDeltaG = deltaG
            self?.liveNormG = normG
        }

        // Auxiliary triggers callback (power unplugged, lid opened, wake)
        SystemTriggers.shared.onTriggerTripped = { [weak self] reason in
            self?.handleTrigger(reason: reason)
        }

        SystemTriggers.shared.onLidClosedChanged = { [weak self] isClosed in
            self?.evaluateLidTransition(isLidClosed: isClosed)
        }

        // When the user locks the screen (⌃⌘Q / Lock Screen) while in Standby -> automatically arm!
        SystemTriggers.shared.onScreenLocked = { [weak self] in
            guard let self = self else { return }
            if self.state == .standby {
                guard !(self.requireChargerToArm && !SystemTriggers.shared.isACPowerConnected) else { return }
                AudioController.shared.playLidLockedSound()
                _ = self.startArming()
            }
        }

        // When the user unlocks the screen (Touch ID / password / Apple Watch) -> return to Standby (active use)!
        SystemTriggers.shared.onScreenUnlocked = { [weak self] in
            guard let self = self else { return }
            switch self.state {
            case .arming, .armed, .gracePeriod, .countdown, .alarmActive:
                self.returnToStandby()
            case .disarmed, .standby:
                break
            }
        }
    }

    private func evaluateLidTransition(isLidClosed: Bool) {
        let wasOpen = (lidLockState == .open)

        // If in Standby and the user closes the lid -> automatically lock, play phone-lock sound, and arm!
        if state == .standby, isLidClosed, wasOpen {
            guard !(requireChargerToArm && !SystemTriggers.shared.isACPowerConnected) else { return }
            completeArming()
            if lockScreenOnLidClose && !ScreenLocker.hasExternalDisplay {
                _ = ScreenLocker.lock(reason: "lid closed while Tjuv is in standby")
            }
            lidLockState = .closedHandled
            AudioController.shared.playLidLockedSound()
            return
        }

        let isArmed = (state == .armed || isTriggeredState)
        let lidSleepOff = SleepManager.shared.isDisabledByUs || SleepManager.shared.isSystemSleepCurrentlyDisabled
        let shouldLock = lidLockState.shouldLock(
            isEnabled: lockScreenOnLidClose,
            isArmed: isArmed,
            isLidClosed: isLidClosed,
            lidSleepDisabledByUs: lidSleepOff,
            hasExternalDisplay: ScreenLocker.hasExternalDisplay
        )
        let locked = shouldLock ? ScreenLocker.lock(reason: "lid closed while Tjuv is armed") : false
        lidLockState = lidLockState.next(isLidClosed: isLidClosed, locked: locked)

        // When the lid transitions from open to closed while already armed/gracePeriod:
        // cancel any motion grace period caused by closing the lid, recalibrate IMU, and play locking sound.
        if isLidClosed && wasOpen && isArmed {
            if case .gracePeriod = state {
                graceTimer?.invalidate()
                graceTimer = nil
                FloatingAlertHUD.shared.hide()
                transition(to: .armed)
            }
            MotionDetector.shared.resetCalibration()
            AudioController.shared.playLidLockedSound()
        }
    }

    private var isTriggeredState: Bool {
        switch state {
        case .gracePeriod, .countdown, .alarmActive: return true
        default: return false
        }
    }

    // MARK: - Public Actions

    /// Master switch toggle from `MenuPanel`: switches between `.standby` (ON) and `.disarmed` (OFF).
    func setMasterEnabled(_ enabled: Bool) {
        if enabled {
            isMasterEnabled = true
            enterStandby()
        } else {
            switch state {
            case .disarmed, .standby:
                isMasterEnabled = false
                forceDisarm()
            case .arming, .armed, .gracePeriod, .countdown, .alarmActive:
                AuthManager.shared.authenticateToDisarm { [weak self] success in
                    guard let self = self, success else { return }
                    self.isMasterEnabled = false
                    self.forceDisarm()
                }
            }
        }
    }

    /// Enters Standby (Active use): Tjuv is ON, passively waiting for the screen to lock or the lid to close.
    func enterStandby() {
        isMasterEnabled = true
        stopAllTimersAndAudio()
        MotionDetector.shared.disarm()
        MotionDetector.shared.startMonitoring()
        SystemTriggers.shared.startStandbyMonitoring()
        SleepManager.shared.preventSleep()
        lidLockState = SystemTriggers.shared.isLidClosed() ? .closedHandled : .open
        FloatingAlertHUD.shared.hide()
        startReconcileTimer()
        transition(to: .standby)
    }

    /// Returns from an armed or triggered state back to `.standby` when the user unlocks their Mac.
    func returnToStandby() {
        guard isMasterEnabled else {
            forceDisarm()
            return
        }
        enterStandby()
    }

    /// Locks the screen immediately and arms Tjuv when the user clicks "Lock & Arm Now".
    @discardableResult
    func lockAndArmNow() -> (success: Bool, message: String?) {
        if requireChargerToArm && !SystemTriggers.shared.isACPowerConnected {
            return (false, "Charger is not connected.\n\nTjuv is configured to require an active power adapter before arming.")
        }
        isMasterEnabled = true
        AudioController.shared.playLidLockedSound()
        let result = startArming()
        _ = ScreenLocker.lock(reason: "manual Lock & Arm Now")
        return result
    }

    @discardableResult
    func toggleArm() -> (success: Bool, message: String?) {
        switch state {
        case .disarmed, .standby:
            return startArming()
        case .arming, .armed, .gracePeriod, .countdown, .alarmActive:
            requestDisarm()
            return (true, nil)
        }
    }

    @discardableResult
    func startArming() -> (success: Bool, message: String?) {
        if requireChargerToArm && !SystemTriggers.shared.isACPowerConnected {
            return (false, "Charger is not connected.\n\nTjuv is configured to require an active power adapter before arming. Please connect your charger or uncheck 'Require Charger to Arm' in the menu.")
        }

        isMasterEnabled = true
        let delay = armingDelaySeconds
        if delay > 0 {
            transition(to: .arming(remainingSeconds: delay))
            armingTimer?.invalidate()
            armingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                guard let self = self else { return }
                if case .arming(let remaining) = self.state {
                    let next = remaining - 1
                    if next > 0 {
                        self.transition(to: .arming(remainingSeconds: next))
                    } else {
                        timer.invalidate()
                        self.armingTimer = nil
                        self.completeArming()
                    }
                }
            }
        } else {
            completeArming()
        }
        return (true, nil)
    }

    private func completeArming() {
        SleepManager.shared.preventSleep()
        lidLockState = SystemTriggers.shared.isLidClosed() ? .closedHandled : .open

        MotionDetector.shared.startMonitoring()
        MotionDetector.shared.arm()
        SystemTriggers.shared.arm()

        startReconcileTimer()
        transition(to: .armed)
    }

    private func startReconcileTimer() {
        // Reconcile sleep & battery every 5 seconds while enabled (coexists with thumbs-out)
        batteryCheckTimer?.invalidate()
        batteryCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self, self.state.isEnabled else { return }
            if let pct = SystemTriggers.shared.currentBatteryPercentage, pct <= 8, !SystemTriggers.shared.isACPowerConnected {
                print("Battery critically low (\(pct)%). Disarming Tjuv to preserve battery.")
                self.forceDisarm()
                return
            }
            // If another app (such as thumbs-out) turned SleepDisabled off when an agent finished
            // while Tjuv still has closed-lid protection enabled, re-assert SleepDisabled = 1.
            if SleepManager.shared.closedLidProtectionEnabled && SleepManager.shared.isSetUp && !SleepManager.shared.isSystemSleepCurrentlyDisabled {
                SleepManager.shared.preventSleep()
            }
        }
    }

    func requestDisarm() {
        AuthManager.shared.authenticateToDisarm { [weak self] success in
            guard let self = self else { return }
            if success {
                self.returnToStandby()
            }
        }
    }

    func forceDisarm() {
        stopAllTimersAndAudio()
        MotionDetector.shared.disarm()
        MotionDetector.shared.stopMonitoring()
        SystemTriggers.shared.disarm()
        SleepManager.shared.restoreNormalSleep()
        lidLockState = .unknown
        FloatingAlertHUD.shared.hide()
        transition(to: .disarmed)
    }

    private func stopAllTimersAndAudio() {
        armingTimer?.invalidate()
        armingTimer = nil
        graceTimer?.invalidate()
        graceTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        batteryCheckTimer?.invalidate()
        batteryCheckTimer = nil
        AudioController.shared.stopAlarm()
    }

    // MARK: - Trigger Handling

    /// Gives the user a 3-second grace period with two short warning beeps to put the laptop back down still.
    private func handleMotionGracePeriod() {
        guard state == .armed else { return }

        MotionDetector.shared.beginGracePeriod()
        var remaining = gracePeriodSeconds
        transition(to: .gracePeriod(remainingSeconds: remaining))

        AudioController.shared.playGraceWarningDoubleBeep()

        FloatingAlertHUD.shared.showGracePeriod(secondsRemaining: remaining) { [weak self] in
            self?.requestDisarm()
        }

        graceTimer?.invalidate()
        graceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            remaining -= 1
            if remaining > 0 {
                self.transition(to: .gracePeriod(remainingSeconds: remaining))
                FloatingAlertHUD.shared.updateGracePeriod(secondsRemaining: remaining)
            } else {
                timer.invalidate()
                self.graceTimer = nil
                if MotionDetector.shared.settleIfStillAfterGracePeriod() {
                    FloatingAlertHUD.shared.hide()
                    self.transition(to: .armed)
                } else {
                    self.escalateToCountdown(reason: "Computer physically moved")
                }
            }
        }
    }

    private func handleTrigger(reason: String) {
        if reason == "Power adapter unplugged", state == .armed {
            handlePowerUnplugGracePeriod(reason: reason)
            return
        }
        switch state {
        case .armed, .gracePeriod:
            graceTimer?.invalidate()
            graceTimer = nil
            escalateToCountdown(reason: reason)
        default:
            return
        }
    }

    /// Gives a 3-second grace period with two short warning beeps when the charger is unplugged;
    /// if AC power is reconnected within 3 seconds, cancels automatically and returns to `.armed`.
    private func handlePowerUnplugGracePeriod(reason: String) {
        var remaining = gracePeriodSeconds
        transition(to: .gracePeriod(remainingSeconds: remaining))
        AudioController.shared.playGraceWarningDoubleBeep()
        FloatingAlertHUD.shared.showGracePeriod(secondsRemaining: remaining) { [weak self] in
            self?.requestDisarm()
        }

        graceTimer?.invalidate()
        graceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            if SystemTriggers.shared.isACPowerConnected {
                timer.invalidate()
                self.graceTimer = nil
                FloatingAlertHUD.shared.hide()
                self.transition(to: .armed)
                return
            }
            remaining -= 1
            if remaining > 0 {
                self.transition(to: .gracePeriod(remainingSeconds: remaining))
                FloatingAlertHUD.shared.updateGracePeriod(secondsRemaining: remaining)
            } else {
                timer.invalidate()
                self.graceTimer = nil
                if SystemTriggers.shared.isACPowerConnected {
                    FloatingAlertHUD.shared.hide()
                    self.transition(to: .armed)
                } else {
                    self.escalateToCountdown(reason: reason)
                }
            }
        }
    }

    private func escalateToCountdown(reason: String) {
        if lockScreenOnTrigger {
            _ = ScreenLocker.lock(reason: "theft trigger tripped: \(reason)")
        }

        let countdownSecs = countdownDurationSeconds
        transition(to: .countdown(remainingSeconds: countdownSecs, reason: reason))

        AudioController.shared.playFriendlyCountdownBeep()

        FloatingAlertHUD.shared.showCountdown(secondsRemaining: countdownSecs, reason: reason) { [weak self] in
            self?.requestDisarm()
        }

        countdownTimer?.invalidate()
        var remaining = countdownSecs
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            remaining -= 1
            if remaining > 0 {
                self.transition(to: .countdown(remainingSeconds: remaining, reason: reason))
                AudioController.shared.playFriendlyCountdownBeep()
                FloatingAlertHUD.shared.updateCountdown(secondsRemaining: remaining)
            } else {
                timer.invalidate()
                self.countdownTimer = nil
                self.activateAlarm(reason: reason)
            }
        }
    }

    private func activateAlarm(reason: String) {
        transition(to: .alarmActive(reason: reason))

        AudioController.shared.startFullAlarm()

        FloatingAlertHUD.shared.showAlarm(reason: reason) { [weak self] in
            self?.requestDisarm()
        }
    }

    // MARK: - Helper

    private func transition(to newState: AlarmState) {
        self.state = newState
        self.onStateChanged?(newState)
    }
}
