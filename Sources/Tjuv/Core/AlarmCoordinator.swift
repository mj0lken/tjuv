import Foundation
import AppKit

enum AlarmState: Equatable {
    case disarmed
    case arming(remainingSeconds: Int)
    case armed
    case countdown(remainingSeconds: Int, reason: String)
    case alarmActive(reason: String)
}

final class AlarmCoordinator: ObservableObject {
    static let shared = AlarmCoordinator()
    
    @Published private(set) var state: AlarmState = .disarmed
    @Published private(set) var liveDeltaG: Double = 0.0
    @Published private(set) var liveNormG: Double = 1.0
    
    var onStateChanged: ((AlarmState) -> Void)?
    
    // User Settings
    var armingDelaySeconds: Int {
        get { UserDefaults.standard.object(forKey: "armingDelaySeconds") as? Int ?? 5 }
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
    
    private var lidLockState: LidLockState = .unknown
    private var armingTimer: Timer?
    private var countdownTimer: Timer?
    private var batteryCheckTimer: Timer?
    
    init() {
        setupSensorCallbacks()
    }
    
    // MARK: - Setup Callbacks
    
    private func setupSensorCallbacks() {
        // Accelerometer motion callback
        MotionDetector.shared.onMotionDetected = { [weak self] in
            self?.handleTrigger(reason: "Computer physically moved")
        }
        
        MotionDetector.shared.onMotionSample = { [weak self] deltaG, normG in
            self?.liveDeltaG = deltaG
            self?.liveNormG = normG
        }
        
        // Auxiliary triggers callback
        SystemTriggers.shared.onTriggerTripped = { [weak self] reason in
            self?.handleTrigger(reason: reason)
        }
        
        SystemTriggers.shared.onLidClosedChanged = { [weak self] isClosed in
            self?.evaluateLidLock(isLidClosed: isClosed)
        }
    }
    
    private func evaluateLidLock(isLidClosed: Bool) {
        let isArmed = (state == .armed || isTriggeredState)
        let shouldLock = lidLockState.shouldLock(
            isEnabled: lockScreenOnLidClose,
            isArmed: isArmed,
            isLidClosed: isLidClosed,
            lidSleepDisabledByUs: SleepManager.shared.isDisabledByUs,
            hasExternalDisplay: ScreenLocker.hasExternalDisplay
        )
        let locked = shouldLock ? ScreenLocker.lock(reason: "lid closed while Tjuv is armed") : false
        lidLockState = lidLockState.next(isLidClosed: isLidClosed, locked: locked)
    }
    
    private var isTriggeredState: Bool {
        switch state {
        case .countdown, .alarmActive: return true
        default: return false
        }
    }
    
    // MARK: - Public Actions
    
    @discardableResult
    func toggleArm() -> (success: Bool, message: String?) {
        switch state {
        case .disarmed:
            return startArming()
        case .arming, .armed, .countdown, .alarmActive:
            requestDisarm()
            return (true, nil)
        }
    }
    
    @discardableResult
    func startArming() -> (success: Bool, message: String?) {
        // Check charger connected if required
        if requireChargerToArm && !SystemTriggers.shared.isACPowerConnected {
            return (false, "Charger is not connected.\n\nTjuv is configured to require an active power adapter before arming. Please connect your charger or uncheck 'Require Charger to Arm' in the menu.")
        }
        
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
        // Activate power assertions / closed lid mode
        SleepManager.shared.preventSleep()
        lidLockState = SystemTriggers.shared.isLidClosed() ? .closedHandled : .open
        
        // Arm motion and triggers
        MotionDetector.shared.startMonitoring()
        MotionDetector.shared.arm()
        SystemTriggers.shared.arm()
        
        // Start battery guard timer: if battery < 8%, auto-disarm to protect hardware
        batteryCheckTimer?.invalidate()
        batteryCheckTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self = self, self.state == .armed else { return }
            if let pct = SystemTriggers.shared.currentBatteryPercentage, pct <= 8, !SystemTriggers.shared.isACPowerConnected {
                print("Battery critically low (\(pct)%). Auto-disarming Tjuv to preserve battery.")
                self.forceDisarm()
            }
        }
        
        transition(to: .armed)
    }
    
    func requestDisarm() {
        AuthManager.shared.authenticateToDisarm { [weak self] success in
            guard let self = self else { return }
            if success {
                self.forceDisarm()
            }
        }
    }
    
    func forceDisarm() {
        armingTimer?.invalidate()
        armingTimer = nil
        
        countdownTimer?.invalidate()
        countdownTimer = nil
        
        batteryCheckTimer?.invalidate()
        batteryCheckTimer = nil
        
        // Stop audio
        AudioController.shared.stopAlarm()
        
        // Disarm sensors
        MotionDetector.shared.disarm()
        MotionDetector.shared.stopMonitoring()
        SystemTriggers.shared.disarm()
        
        // Restore sleep settings
        SleepManager.shared.restoreNormalSleep()
        lidLockState = .unknown
        
        // Hide HUD
        FloatingAlertHUD.shared.hide()
        
        transition(to: .disarmed)
    }
    
    // MARK: - Trigger Handling
    
    private func handleTrigger(reason: String) {
        guard state == .armed else { return }
        
        if lockScreenOnTrigger {
            _ = ScreenLocker.lock(reason: "theft trigger tripped: \(reason)")
        }
        
        let countdownSecs = countdownDurationSeconds
        transition(to: .countdown(remainingSeconds: countdownSecs, reason: reason))
        
        // 1. Play first friendly countdown beep immediately
        AudioController.shared.playFriendlyCountdownBeep()
        
        // 2. Show floating HUD
        FloatingAlertHUD.shared.showCountdown(secondsRemaining: countdownSecs, reason: reason) { [weak self] in
            self?.requestDisarm()
        }
        
        // 3. Start countdown timer
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
        
        // Play full piercing siren exclusively on built-in speakers at MAX volume
        AudioController.shared.startFullAlarm()
        
        // Show alarm HUD
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
