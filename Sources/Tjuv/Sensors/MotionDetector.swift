import Foundation
import IOKit
import IOKit.hid

enum MotionSensitivity: String, CaseIterable, Codable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    
    var accelerationThreshold: Double {
        switch self {
        case .low: return 0.16
        case .medium: return 0.08
        case .high: return 0.04
        }
    }
    
    var tiltThresholdDegrees: Double {
        switch self {
        case .low: return 12.0
        case .medium: return 6.0
        case .high: return 3.0
        }
    }
    
    var requiredConsecutiveHits: Int {
        switch self {
        case .low: return 5
        case .medium: return 3
        case .high: return 2
        }
    }
}

/// Detects physical movement and orientation change using the Apple Silicon internal IMU (AppleSPUHIDDevice).
final class MotionDetector {
    static let shared = MotionDetector()
    
    var sensitivity: MotionSensitivity = .medium
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
        calibrationSamples.removeAll()
        consecutiveHits = 0
        refX = 0
        refY = 0
        refZ = 0
    }
    
    // MARK: - Sample Processing
    
    private func processSample(x: Double, y: Double, z: Double) {
        guard isMonitoring else { return }
        
        // Update low-pass filter (90% history, 10% new sample)
        if smoothX == 0 && smoothY == 0 && smoothZ == 0 {
            smoothX = x
            smoothY = y
            smoothZ = z
        } else {
            smoothX = 0.90 * smoothX + 0.10 * x
            smoothY = 0.90 * smoothY + 0.10 * y
            smoothZ = 0.90 * smoothZ + 0.10 * z
        }
        
        let currentNorm = sqrt(x*x + y*y + z*z)
        
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
        
        // 1. Vector displacement from baseline
        let dx = x - refX
        let dy = y - refY
        let dz = z - refZ
        let deltaNorm = sqrt(dx*dx + dy*dy + dz*dz)
        
        // 2. Tilt angle in degrees
        let dot = (x * refX) + (y * refY) + (z * refZ)
        let refNorm = sqrt(refX*refX + refY*refY + refZ*refZ)
        let cosAngle = max(-1.0, min(1.0, dot / (currentNorm * refNorm)))
        let tiltDegrees = acos(cosAngle) * 180.0 / Double.pi
        
        // Periodically report live motion metrics for UI meters (~20 Hz)
        lastSampleLogCounter += 1
        if lastSampleLogCounter % 40 == 0 {
            DispatchQueue.main.async { [weak self] in
                self?.onMotionSample?(deltaNorm, currentNorm)
            }
        }
        
        // Only evaluate alarm triggers when fully armed
        guard isArmed else { return }
        
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
