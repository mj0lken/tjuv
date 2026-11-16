import Foundation
import AppKit
import CoreGraphics
import IOKit
import IOKit.ps
import os

/// Action emitted by `PowerButtonTracker` when evaluating physical power button state samples.
enum PowerButtonAction: Equatable {
    case none
    case pressed
    case held
}

/// Pure state machine tracking physical power / Touch ID button press and hold transitions.
/// - Emits `.pressed` immediately when the button transitions down (or on a sub-poll tap via `EnqueueEventCount`).
/// - Emits `.held` once when the button remains continuously depressed for `holdDurationThreshold` (default 1.0s).
/// - Ignores any button press that was already held down when `reset` was called until it is first released.
struct PowerButtonTracker {
    let holdDurationThreshold: TimeInterval
    private(set) var isPressed: Bool = false
    private(set) var pressStartTime: TimeInterval?
    private(set) var hasFiredHoldForCurrentPress: Bool = false
    private(set) var lastEnqueueCount: UInt64?
    private(set) var ignoringInitialHold: Bool = false

    init(holdDurationThreshold: TimeInterval = 1.0) {
        self.holdDurationThreshold = holdDurationThreshold
    }

    mutating func reset(isCurrentlyDown: Bool, currentEnqueueCount: UInt64?) {
        isPressed = false
        pressStartTime = nil
        hasFiredHoldForCurrentPress = false
        lastEnqueueCount = currentEnqueueCount
        ignoringInitialHold = isCurrentlyDown
    }

    mutating func update(
        isCurrentlyDown: Bool,
        currentEnqueueCount: UInt64?,
        now: TimeInterval
    ) -> PowerButtonAction {
        if ignoringInitialHold {
            lastEnqueueCount = currentEnqueueCount
            if !isCurrentlyDown {
                ignoringInitialHold = false
            }
            return .none
        }

        if isCurrentlyDown {
            lastEnqueueCount = currentEnqueueCount
            if !isPressed {
                isPressed = true
                pressStartTime = now
                hasFiredHoldForCurrentPress = false
                return .pressed
            } else {
                if !hasFiredHoldForCurrentPress,
                   let start = pressStartTime,
                   (now - start) >= holdDurationThreshold {
                    hasFiredHoldForCurrentPress = true
                    return .held
                }
                return .none
            }
        } else {
            if isPressed {
                // Button was just released; the EnqueueEventCount increment corresponds to this release.
                isPressed = false
                pressStartTime = nil
                hasFiredHoldForCurrentPress = false
                lastEnqueueCount = currentEnqueueCount
                return .none
            } else {
                // Neither down now nor down on the previous sample: detect ultra-brief sub-poll taps.
                if let current = currentEnqueueCount, let last = lastEnqueueCount, current > last {
                    lastEnqueueCount = current
                    return .pressed
                }
                lastEnqueueCount = currentEnqueueCount
                return .none
            }
        }
    }
}

/// Monitors auxiliary theft triggers: Power adapter unplugged, lid opened, power button press/hold, and system wake.
final class SystemTriggers: NSObject {
    static let shared = SystemTriggers()
    private static let log = Logger(subsystem: "com.mj0lken.tjuv", category: "lock")

    /// `kIOPMMessageClamshellStateChange` (`iokit_family_msg(sub_iokit_powermanagement, 0x100)`)
    private static let clamshellStateChange: natural_t = 0xE003_4100
    private static let closedBit: UInt = 1 << 0
    
    var triggerOnPowerUnplugged: Bool = {
        if UserDefaults.standard.object(forKey: "triggerOnPowerUnplugged") == nil { return true }
        return UserDefaults.standard.bool(forKey: "triggerOnPowerUnplugged")
    }() {
        didSet {
            UserDefaults.standard.set(triggerOnPowerUnplugged, forKey: "triggerOnPowerUnplugged")
            DispatchQueue.main.async { AlarmCoordinator.shared.objectWillChange.send() }
        }
    }

    var triggerOnLidOpened: Bool = {
        if UserDefaults.standard.object(forKey: "triggerOnLidOpened") == nil { return true }
        return UserDefaults.standard.bool(forKey: "triggerOnLidOpened")
    }() {
        didSet {
            UserDefaults.standard.set(triggerOnLidOpened, forKey: "triggerOnLidOpened")
            DispatchQueue.main.async { AlarmCoordinator.shared.objectWillChange.send() }
        }
    }

    var triggerOnPowerButton: Bool = {
        if UserDefaults.standard.object(forKey: "triggerOnPowerButton") == nil { return true }
        return UserDefaults.standard.bool(forKey: "triggerOnPowerButton")
    }() {
        didSet {
            UserDefaults.standard.set(triggerOnPowerButton, forKey: "triggerOnPowerButton")
            DispatchQueue.main.async { AlarmCoordinator.shared.objectWillChange.send() }
        }
    }
    
    var onTriggerTripped: ((_ reason: String) -> Void)?
    var onPowerButtonPressed: (() -> Void)?
    var onPowerButtonHeld: ((_ reason: String) -> Void)?
    var onLidClosedChanged: ((_ isClosed: Bool) -> Void)?
    var onScreenLocked: (() -> Void)?
    var onScreenUnlocked: (() -> Void)?
    
    private var isStandbyOrArmed = false
    private var isArmed = false
    private var initialPowerSourceState: String?
    private var initialLidClosedState: Bool?
    private var lastScreenLockedState: Bool = false
    private var lastLockEventTime: Date = .distantPast
    private var powerRunLoopSource: CFRunLoopSource?
    private var lidCheckTimer: Timer?
    private var powerButtonTimer: Timer?
    private var powerButtonService: io_service_t = 0
    private var powerButtonTracker = PowerButtonTracker(holdDurationThreshold: 1.0)
    private var clamshellNotificationPort: IONotificationPortRef?
    private var clamshellNotificationObject: io_object_t = 0
    
    override init() {
        super.init()
        lastScreenLockedState = isScreenLocked()
        setupPowerButtonService()
        setupWakeNotification()
        setupClamshellInterestNotification()
    }
    
    deinit {
        stopMonitoring()
        if powerButtonService != 0 {
            IOObjectRelease(powerButtonService)
            powerButtonService = 0
        }
    }
    
    // MARK: - Standby, Arming & Disarming

    func startStandbyMonitoring() {
        isStandbyOrArmed = true
        isArmed = false
        if let source = powerRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
            powerRunLoopSource = nil
        }
        powerButtonTimer?.invalidate()
        powerButtonTimer = nil
        initialLidClosedState = isLidClosed()
        lastScreenLockedState = isScreenLocked()
        startLidMonitoring()
    }
    
    func arm() {
        isStandbyOrArmed = true
        isArmed = true
        initialPowerSourceState = getCurrentPowerSourceState()
        initialLidClosedState = isLidClosed()
        if isScreenLocked() {
            lastScreenLockedState = true
            lastLockEventTime = Date()
        }
        
        startPowerMonitoring()
        startLidMonitoring()
        startPowerButtonMonitoring()
    }
    
    func disarm() {
        isStandbyOrArmed = false
        isArmed = false
        stopMonitoring()
    }
    
    private func stopMonitoring() {
        if let source = powerRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
            powerRunLoopSource = nil
        }
        lidCheckTimer?.invalidate()
        lidCheckTimer = nil
        powerButtonTimer?.invalidate()
        powerButtonTimer = nil
    }
    
    // MARK: - Power Monitoring
    
    var isACPowerConnected: Bool {
        return getCurrentPowerSourceState() == kIOPSACPowerValue
    }
    
    var currentBatteryPercentage: Int? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in sources {
            if let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
               let cur = desc[kIOPSCurrentCapacityKey] as? Int,
               let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                return Int((Double(cur) / Double(max)) * 100.0)
            }
        }
        return nil
    }
    
    var powerStatusSummary: String {
        let isAC = isACPowerConnected
        let pct = currentBatteryPercentage
        if isAC {
            if let pct = pct {
                return "⚡ AC Connected (\(pct)%)"
            }
            return "⚡ AC Connected"
        } else {
            if let pct = pct {
                return "🔋 On Battery (\(pct)%)"
            }
            return "🔋 On Battery"
        }
    }
    
    func getCurrentPowerSourceState() -> String? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in sources {
            if let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] {
                return desc[kIOPSPowerSourceStateKey] as? String
            }
        }
        return nil
    }
    
    private func startPowerMonitoring() {
        let callback: IOPowerSourceCallbackType = { context in
            guard let ctx = context else { return }
            let triggers = Unmanaged<SystemTriggers>.fromOpaque(ctx).takeUnretainedValue()
            triggers.handlePowerSourceChange()
        }
        
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            powerRunLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
        }
    }
    
    private func handlePowerSourceChange() {
        guard isArmed, triggerOnPowerUnplugged else { return }
        let currentState = getCurrentPowerSourceState()
        
        // If it was on AC Power and now is on Battery Power -> Unplugged!
        if initialPowerSourceState == kIOPSACPowerValue && currentState == kIOPSBatteryPowerValue {
            DispatchQueue.main.async { [weak self] in
                self?.onTriggerTripped?("Power adapter unplugged")
            }
        }
    }
    
    // MARK: - Lid Monitoring (Instant IOKit Clamshell Interrupt + 0.5s Poll)

    private static let clamshellCallback: IOServiceInterestCallback = { refcon, _, messageType, argument in
        guard messageType == SystemTriggers.clamshellStateChange, let refcon else { return }
        let isClosed = UInt(bitPattern: argument) & SystemTriggers.closedBit != 0
        let triggers = Unmanaged<SystemTriggers>.fromOpaque(refcon).takeUnretainedValue()
        DispatchQueue.main.async {
            guard triggers.isStandbyOrArmed else { return }
            SystemTriggers.log.notice("Clamshell state changed: isClosed=\(isClosed, privacy: .public) (lid event)")
            triggers.handleLidStateObservation(currentLidClosed: isClosed)
        }
    }

    private func setupClamshellInterestNotification() {
        guard clamshellNotificationPort == nil else { return }
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { if rootDomain != 0 { IOObjectRelease(rootDomain) } }
        guard rootDomain != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else {
            Self.log.error("Failed to create IONotificationPort for clamshell events")
            return
        }
        IONotificationPortSetDispatchQueue(port, .main)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddInterestNotification(
            port,
            rootDomain,
            kIOGeneralInterest,
            Self.clamshellCallback,
            refcon,
            &clamshellNotificationObject
        )
        if result == KERN_SUCCESS {
            clamshellNotificationPort = port
        } else {
            IONotificationPortDestroy(port)
            Self.log.error("IOServiceAddInterestNotification for clamshell failed: \(result)")
        }
    }

    private func handleLidStateObservation(currentLidClosed: Bool) {
        onLidClosedChanged?(currentLidClosed)
        if isArmed, triggerOnLidOpened, initialLidClosedState == true && currentLidClosed == false {
            initialLidClosedState = false
            Self.log.notice("Armed lid opened -> triggering countdown")
            DispatchQueue.main.async {
                self.onTriggerTripped?("Laptop lid opened")
            }
        } else {
            initialLidClosedState = currentLidClosed
        }
    }

    func isLidClosed() -> Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return false }
        defer { IOObjectRelease(rootDomain) }
        
        var props: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(rootDomain, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
           let dict = props?.takeRetainedValue() as? [String: Any] {
            return dict["AppleClamshellClosed"] as? Bool ?? false
        }
        return false
    }
    
    func isScreenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    private func startLidMonitoring() {
        lidCheckTimer?.invalidate()
        lidCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.isStandbyOrArmed else { return }

            // 1. Check screen lock/unlock transitions via CGSessionCopyCurrentDictionary()
            let currentScreenLocked = self.isScreenLocked()
            if currentScreenLocked != self.lastScreenLockedState {
                if currentScreenLocked {
                    self.lastScreenLockedState = true
                    self.lastLockEventTime = Date()
                    self.onScreenLocked?()
                } else if Date().timeIntervalSince(self.lastLockEventTime) > 1.5 {
                    self.lastScreenLockedState = false
                    self.onScreenUnlocked?()
                }
            }

            // 2. Check lid closed/open transitions
            let currentLidClosed = self.isLidClosed()
            self.handleLidStateObservation(currentLidClosed: currentLidClosed)
        }
    }

    // MARK: - Power Button Monitoring (AppleM68Buttons / PMU Hold Button)

    var isPowerButtonHardwareAvailable: Bool {
        return powerButtonService != 0
    }

    private func setupPowerButtonService() {
        guard powerButtonService == 0 else { return }
        for className in ["AppleM68Buttons", "AppleEmbeddedButtonController"] {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
            guard service != 0 else { continue }
            if Self.hasReadableButtonDebugState(service) {
                powerButtonService = service
                return
            }
            IOObjectRelease(service)
        }
    }

    private static func hasReadableButtonDebugState(_ service: io_service_t) -> Bool {
        if IORegistryEntryCreateCFProperty(
            service,
            "DebugState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() is [String: Any] {
            return true
        }
        var iter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iter) == kIOReturnSuccess else {
            return false
        }
        defer { IOObjectRelease(iter) }
        var child = IOIteratorNext(iter)
        while child != 0 {
            defer {
                IOObjectRelease(child)
                child = IOIteratorNext(iter)
            }
            if let childDebug = IORegistryEntryCreateCFProperty(
                child,
                "DebugState" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any],
               childDebug["EnqueueEventCount"] != nil {
                return true
            }
        }
        return false
    }

    /// Reads the physical power / Touch ID button mechanical state directly from `AppleM68Buttons` in IORegistry.
    /// Requires no TCC / Accessibility / Input Monitoring permissions and works even while the screen is locked.
    func readPowerButtonHardwareState() -> (isDown: Bool, enqueueCount: UInt64?) {
        if powerButtonService == 0 {
            setupPowerButtonService()
        }
        guard powerButtonService != 0 else { return (false, nil) }

        var isDown = false
        if let debug = IORegistryEntryCreateCFProperty(
            powerButtonService,
            "DebugState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [String: Any] {
            let stateMask = (debug["ButtonStateMask"] as? NSNumber)?.uint64Value ?? 0
            let filteredMask = (debug["ButtonDownFilteredMask"] as? NSNumber)?.uint64Value ?? 0
            let unfilteredMask = (debug["ButtonUnfilteredMask"] as? NSNumber)?.uint64Value ?? 0
            isDown = (stateMask | filteredMask | unfilteredMask) != 0
        }

        var enqueueCount: UInt64?
        var iter: io_iterator_t = 0
        if IORegistryEntryGetChildIterator(powerButtonService, kIOServicePlane, &iter) == kIOReturnSuccess {
            defer { IOObjectRelease(iter) }
            var child = IOIteratorNext(iter)
            while child != 0 {
                defer {
                    IOObjectRelease(child)
                    child = IOIteratorNext(iter)
                }
                if let childDebug = IORegistryEntryCreateCFProperty(
                    child,
                    "DebugState" as CFString,
                    kCFAllocatorDefault,
                    0
                )?.takeRetainedValue() as? [String: Any],
                   let count = (childDebug["EnqueueEventCount"] as? NSNumber)?.uint64Value {
                    enqueueCount = count
                    break
                }
            }
        }

        return (isDown, enqueueCount)
    }

    private func startPowerButtonMonitoring() {
        powerButtonTimer?.invalidate()
        powerButtonTimer = nil
        guard isPowerButtonHardwareAvailable else { return }

        let initial = readPowerButtonHardwareState()
        powerButtonTracker.reset(isCurrentlyDown: initial.isDown, currentEnqueueCount: initial.enqueueCount)

        powerButtonTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            guard let self = self, self.isArmed, self.triggerOnPowerButton else { return }
            let snapshot = self.readPowerButtonHardwareState()
            let action = self.powerButtonTracker.update(
                isCurrentlyDown: snapshot.isDown,
                currentEnqueueCount: snapshot.enqueueCount,
                now: ProcessInfo.processInfo.systemUptime
            )
            switch action {
            case .none:
                break
            case .pressed:
                Self.log.notice("Physical power button pressed while armed -> playing warning beep")
                self.onPowerButtonPressed?()
            case .held:
                Self.log.notice("Physical power button held down >= 1.0s while armed -> activating full alarm")
                self.onPowerButtonHeld?("Power button held down")
            }
        }
    }
    
    // MARK: - Wake & Screen Lock Notifications
    
    private func setupWakeNotification() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isArmed else { return }
            self.onTriggerTripped?("Computer woke from sleep")
        }
        
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isArmed else { return }
            self.onTriggerTripped?("Screen activated")
        }

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleScreenLockedNotification(_:)),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleScreenUnlockedNotification(_:)),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func handleScreenLockedNotification(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isStandbyOrArmed else { return }
            self.lastLockEventTime = Date()
            guard !self.lastScreenLockedState else { return }
            self.lastScreenLockedState = true
            self.onScreenLocked?()
        }
    }

    @objc private func handleScreenUnlockedNotification(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isStandbyOrArmed else { return }
            self.lastScreenLockedState = false
            self.onScreenUnlocked?()
        }
    }
}
