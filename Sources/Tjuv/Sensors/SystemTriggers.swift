import Foundation
import AppKit
import IOKit
import IOKit.ps

/// Monitors auxiliary theft triggers: Power adapter unplugged, lid opened, and system wake.
final class SystemTriggers {
    static let shared = SystemTriggers()
    
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
    
    var onTriggerTripped: ((_ reason: String) -> Void)?
    var onLidClosedChanged: ((_ isClosed: Bool) -> Void)?
    
    private var isArmed = false
    private var initialPowerSourceState: String?
    private var initialLidClosedState: Bool?
    private var powerRunLoopSource: CFRunLoopSource?
    private var lidCheckTimer: Timer?
    
    init() {
        setupWakeNotification()
    }
    
    deinit {
        stopMonitoring()
    }
    
    // MARK: - Arming & Disarming
    
    func arm() {
        isArmed = true
        initialPowerSourceState = getCurrentPowerSourceState()
        initialLidClosedState = isLidClosed()
        
        startPowerMonitoring()
        startLidMonitoring()
    }
    
    func disarm() {
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
    
    // MARK: - Lid Monitoring
    
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
    
    private func startLidMonitoring() {
        lidCheckTimer?.invalidate()
        lidCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.isArmed else { return }
            let currentLidClosed = self.isLidClosed()
            self.onLidClosedChanged?(currentLidClosed)
            
            // If it was closed and has now been opened
            if self.triggerOnLidOpened, self.initialLidClosedState == true && currentLidClosed == false {
                self.initialLidClosedState = false
                DispatchQueue.main.async {
                    self.onTriggerTripped?("Laptop lid opened")
                }
            } else {
                self.initialLidClosedState = currentLidClosed
            }
        }
    }
    
    // MARK: - Wake Notification
    
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
    }
}
