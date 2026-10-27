import Foundation
import IOKit
import IOKit.hid

enum MotionSensitivity: String, CaseIterable, Codable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    
    var accelerationThreshold: Double {
        switch self {
        case .low: return 0.18
        case .medium: return 0.10
        case .high: return 0.05
        }
    }
    
    var tiltThresholdDegrees: Double {
        switch self {
        case .low: return 12.0
        case .medium: return 7.0
        case .high: return 3.5
        }
    }
    
    var requiredConsecutiveHits: Int {
        switch self {
        case .low: return 48
        case .medium: return 28
        case .high: return 16
        }
    }
}

/// Detects physical movement and orientation change using the Apple Silicon internal IMU (AppleSPUHIDDevice).
final class MotionDetector {
    static let shared = MotionDetector()
    
    var sensitivity: MotionSensitivity = {
        if let raw = UserDefaults.standard.string(forKey: "motionSensitivity"),
           let val = MotionSensitivity(rawValue: raw) {
            return val
        }
        return .medium
    }() {
        didSet {
            UserDefaults.standard.set(sensitivity.rawValue, forKey: "motionSensitivity")
            DispatchQueue.main.async {
                AlarmCoordinator.shared.objectWillChange.send()
            }
        }
    }
    var onMotionDetected: (() -> Void)?
    var onMotionSample: ((_ deltaG: Double, _ normG: Double) -> Void)?
    
    private var hidManager: IOHIDManager?
    private var isMonitoring = false
    private var isArmed = false
    
    // Baseline resting orientation
    private var refX: Double = 0.0
    private var refY: Double = 0.0
    private var refZ: Double = 0.0
    private var isCalibrated = false
    private var calibrationSamples: [(Double, Double, Double)] = []
    private let targetCalibrationCount = 80
    
    // Low-pass filter for smooth motion tracking
    private var smoothX: Double = 0.0
    private var smoothY: Double = 0.0
    private var smoothZ: Double = 0.0

    // Rolling short-window baseline for detecting whether the laptop has been placed back down still
    private var rollingX: Double = 0.0
    private var rollingY: Double = 0.0
    private var rollingZ: Double = 0.0
    private var isInGracePeriod = false
    private var lastDynamicMotionTime: TimeInterval = 0
    
    // Debounce / Consecutive hit counter
    private var consecutiveHits = 0
    private var lastSampleTime: TimeInterval = 0
    private var lastSampleLogCounter = 0
    
    var isHardwareAvailable: Bool {
        return hidManager != nil
    }
    
    init() {
        setupHIDManager()
    }
    
    deinit {
        stopMonitoring()
    }
    
    // MARK: - HID Setup
    
    private func setupHIDManager() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matchDict: [String: Any] = [
            kIOHIDPrimaryUsagePageKey: 0xFF00,
            kIOHIDPrimaryUsageKey: 0x03
        ]
        IOHIDManagerSetDeviceMatching(manager, matchDict as CFDictionary)
        let openStatus = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        
        guard openStatus == kIOReturnSuccess else {
            print("Notice: Apple Silicon SPU accelerometer not directly available (code: \(openStatus))")
            return
        }
        
        let callback: IOHIDReportCallback = { context, result, sender, type, reportID, report, reportLength in
            guard reportLength >= 18, let ctx = context else { return }
            let detector = Unmanaged<MotionDetector>.fromOpaque(ctx).takeUnretainedValue()
            let ptr = UnsafeRawPointer(report)
            let x = Double(ptr.loadUnaligned(fromByteOffset: 6, as: Int32.self)) / 65536.0
            let y = Double(ptr.loadUnaligned(fromByteOffset: 10, as: Int32.self)) / 65536.0
            let z = Double(ptr.loadUnaligned(fromByteOffset: 14, as: Int32.self)) / 65536.0
            detector.processSample(x: x, y: y, z: z)
        }
        
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputReportCallback(manager, callback, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        
        self.hidManager = manager
    }
    
    // MARK: - State Control
    
    func startMonitoring() {
        isMonitoring = true
        resetCalibration()
    }
    
    func stopMonitoring() {
        isMonitoring = false
        isArmed = false
        resetCalibration()
    }
    
    func arm() {
        isArmed = true
        resetCalibration()
    }
    
    func disarm() {
        isArmed = false
        resetCalibration()
    }
    
    func resetCalibration() {
        isCalibrated = false
        isInGracePeriod = false
        calibrationSamples.removeAll()
        consecutiveHits = 0
        refX = 0
        refY = 0
        refZ = 0
    }

    /// Enters the 5-second grace period so the user can return the laptop to a flat and still position without re-firing `onMotionDetected`.
    func beginGracePeriod() {
        isInGracePeriod = true
        consecutiveHits = 0
        lastDynamicMotionTime = ProcessInfo.processInfo.systemUptime
    }

    /// Evaluates whether the laptop has been returned to a flat and still position during or at the end of the 5-second grace period.
    /// If stationary and resting flat (or returned to its armed angle), re-anchors the baseline and returns `true`.
    func settleIfStillAfterGracePeriod(
        requiredStillDuration: TimeInterval = 0.45,
        maxFlatTiltDegrees: Double = 20.0,
        maxTiltFromArmedDegrees: Double = 25.0,
        endGracePeriodIfUnsettled: Bool = true
    ) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let stillDuration = now - lastDynamicMotionTime

        let smoothNorm = sqrt(smoothX * smoothX + smoothY * smoothY + smoothZ * smoothZ)
        let refNorm = sqrt(refX * refX + refY * refY + refZ * refZ)

        // 1. Angle relative to horizontal desk plane (gravity along Z axis)
        var horizontalTiltDegrees = 90.0
        if smoothNorm > 0.1 {
            let cosHorizontal = max(0.0, min(1.0, abs(smoothZ) / smoothNorm))
            horizontalTiltDegrees = acos(cosHorizontal) * 180.0 / Double.pi
        }

        // 2. Angle relative to original armed baseline (supports angled laptop stands)
        var tiltFromOriginal = 90.0
        if smoothNorm > 0.1 && refNorm > 0.1 {
            let dot = (smoothX * refX) + (smoothY * refY) + (smoothZ * refZ)
            let cosAngle = max(-1.0, min(1.0, dot / (smoothNorm * refNorm)))
            tiltFromOriginal = acos(cosAngle) * 180.0 / Double.pi
        }

        let isNearOneG = abs(smoothNorm - 1.0) <= 0.08
        let isFlatPosition = (horizontalTiltDegrees <= maxFlatTiltDegrees) || (tiltFromOriginal <= maxTiltFromArmedDegrees)

        if stillDuration >= requiredStillDuration && isNearOneG && isFlatPosition {
            // Re-anchor baseline to the new flat resting position on the table
            refX = smoothX
            refY = smoothY
            refZ = smoothZ
            consecutiveHits = 0
            isInGracePeriod = false
            return true
        }

        if endGracePeriodIfUnsettled {
            isInGracePeriod = false
        }
        return false
    }
    
    // MARK: - Sample Processing
    
    private func processSample(x: Double, y: Double, z: Double) {
        guard isMonitoring else { return }
        
        // Update low-pass filter (88% history, 12% new sample) to filter out brief desk vibrations
        if smoothX == 0 && smoothY == 0 && smoothZ == 0 {
            smoothX = x
            smoothY = y
            smoothZ = z
            rollingX = x
            rollingY = y
            rollingZ = z
        } else {
            smoothX = 0.88 * smoothX + 0.12 * x
            smoothY = 0.88 * smoothY + 0.12 * y
            smoothZ = 0.88 * smoothZ + 0.12 * z
            rollingX = 0.94 * rollingX + 0.06 * x
            rollingY = 0.94 * rollingY + 0.06 * y
            rollingZ = 0.94 * rollingZ + 0.06 * z
        }

        let dynDx = x - rollingX
        let dynDy = y - rollingY
        let dynDz = z - rollingZ
        let dynamicDelta = sqrt(dynDx * dynDx + dynDy * dynDy + dynDz * dynDz)
        let stillnessThreshold = max(0.035, min(0.06, sensitivity.accelerationThreshold * 0.50))
        if dynamicDelta >= stillnessThreshold {
            lastDynamicMotionTime = ProcessInfo.processInfo.systemUptime
        }
        
        let currentNorm = sqrt(x*x + y*y + z*z)
        let smoothNorm = sqrt(smoothX * smoothX + smoothY * smoothY + smoothZ * smoothZ)
        
        // If not calibrated yet, collect baseline resting samples
        if !isCalibrated {
            calibrationSamples.append((x, y, z))
            if calibrationSamples.count >= targetCalibrationCount {
                refX = calibrationSamples.map { $0.0 }.reduce(0, +) / Double(calibrationSamples.count)
                refY = calibrationSamples.map { $0.1 }.reduce(0, +) / Double(calibrationSamples.count)
                refZ = calibrationSamples.map { $0.2 }.reduce(0, +) / Double(calibrationSamples.count)
                isCalibrated = true
            }
            return
        }
        
        // 1. Smoothed vector displacement from baseline (ignores sub-50ms desk taps/nudges)
        let dx = smoothX - refX
        let dy = smoothY - refY
        let dz = smoothZ - refZ
        let deltaNorm = sqrt(dx*dx + dy*dy + dz*dz)
        
        // 2. Smoothed tilt angle in degrees
        let dot = (smoothX * refX) + (smoothY * refY) + (smoothZ * refZ)
        let refNorm = sqrt(refX*refX + refY*refY + refZ*refZ)
        let cosAngle = max(-1.0, min(1.0, dot / max(0.001, smoothNorm * refNorm)))
        let tiltDegrees = acos(cosAngle) * 180.0 / Double.pi
        
        // Periodically report live motion metrics for UI meters (~20 Hz)
        lastSampleLogCounter += 1
        if lastSampleLogCounter % 40 == 0 {
            DispatchQueue.main.async { [weak self] in
                self?.onMotionSample?(deltaNorm, currentNorm)
            }
        }
        
        // Only evaluate alarm triggers when fully armed and not already in the grace period
        guard isArmed && !isInGracePeriod else { return }
        
        let exceedsAccel = deltaNorm >= sensitivity.accelerationThreshold
        let exceedsTilt = tiltDegrees >= sensitivity.tiltThresholdDegrees
        
        if exceedsAccel || exceedsTilt {
            consecutiveHits += 1
            if consecutiveHits >= sensitivity.requiredConsecutiveHits {
                consecutiveHits = 0
                DispatchQueue.main.async { [weak self] in
                    self?.onMotionDetected?()
                }
            }
        } else {
            // Decay consecutive hits on quiet samples
            if consecutiveHits > 0 {
                consecutiveHits -= 1
            }
        }
    }
}
