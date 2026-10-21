import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

/// Manages audio output exclusively routed to built-in laptop speakers at max volume.
/// Guarantees that alarm audio is never played through connected devices (Bluetooth, AirPods, HDMI, etc.).
final class AudioController {
    static let shared = AudioController()
    
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var sampleRate: Double = 44100.0
    
    private var originalDefaultOutputID: AudioDeviceID?
    private var originalSpeakerVolume: Float32?
    private var isPlayingSiren = false
    private var volumeWatchdogTimer: Timer?
    
    private var countdownToneBuffer: AVAudioPCMBuffer?
    private var sirenBuffer: AVAudioPCMBuffer?
    
    init() {
        setupAudioBuffers()
    }
    
    // MARK: - Hardware Querying
    
    /// Finds the built-in speaker AudioDeviceID.
    func findBuiltInSpeakerID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else {
            return nil
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return nil
        }
        
        for id in deviceIDs {
            // Check if device has output streams
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            if AudioObjectGetPropertyDataSize(id, &streamAddr, 0, nil, &streamSize) == noErr && streamSize > 0 {
                // Check transport type
                var transAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyTransportType,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var transType: UInt32 = 0
                var transSize = UInt32(MemoryLayout<UInt32>.size)
                if AudioObjectGetPropertyData(id, &transAddr, 0, nil, &transSize, &transType) == noErr {
                    if transType == kAudioDeviceTransportTypeBuiltIn {
                        return id
                    }
                }
            }
        }
        return nil
    }
    
    /// Gets the current system-wide default output device ID.
    func getDefaultOutputDeviceID() -> AudioDeviceID? {
        var defaultID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &defaultID)
        return status == noErr ? defaultID : nil
    }
    
    /// Sets the system-wide default output device.
    @discardableResult
    func setDefaultOutputDeviceID(_ id: AudioDeviceID) -> Bool {
        var devID = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, size, &devID)
        return status == noErr
    }
    
    /// Reads the volume of a device.
    func getDeviceVolume(_ deviceID: AudioDeviceID) -> Float32? {
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var vol: Float32 = 0.0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(deviceID, &volAddr, 0, nil, &size, &vol) == noErr {
            return vol
        }
        // Fallback to scalar volume
        var fallbackAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(deviceID, &fallbackAddr, 0, nil, &size, &vol) == noErr {
            return vol
        }
        return nil
    }
    
    /// Forces volume to a given level (0.0 to 1.0).
    @discardableResult
    func setDeviceVolume(_ deviceID: AudioDeviceID, volume: Float32) -> Bool {
        var vol = volume
        let size = UInt32(MemoryLayout<Float32>.size)
        
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let s1 = AudioObjectSetPropertyData(deviceID, &volAddr, 0, nil, size, &vol)
        
        // Also set scalar volume
        var scalarAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let s2 = AudioObjectSetPropertyData(deviceID, &scalarAddr, 0, nil, size, &vol)
        
        return s1 == noErr || s2 == noErr
    }
    
    /// Unmutes the given device.
    @discardableResult
    func unmuteDevice(_ deviceID: AudioDeviceID) -> Bool {
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var isMuted: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &muteAddr, 0, nil, size, &isMuted)
        return status == noErr
    }
    
    // MARK: - Setup Engine & Routing
    
    private func setupEngine(targetDeviceID: AudioDeviceID) throws {
        if engine.isRunning {
            engine.stop()
        }
        engine.reset()
        
        if !engine.attachedNodes.contains(player) {
            engine.attach(player)
        }
        
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        
        // Exclusively bind the AVAudioEngine output unit to the built-in speaker
        guard let outputUnit = engine.outputNode.audioUnit else {
            throw NSError(domain: "TjuvAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No output audio unit"])
        }
        
        var devID = targetDeviceID
        let status = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            print("Warning: AudioUnitSetProperty kAudioOutputUnitProperty_CurrentDevice returned \(status)")
        }
        
        try engine.start()
    }
    
    // MARK: - Sound Synthesis
    
    private func setupAudioBuffers() {
        // 1. Friendly countdown beep: 1000 Hz, 120ms with pleasant fade envelope
        countdownToneBuffer = createToneBuffer(frequency: 1046.5, duration: 0.12, volume: 0.45)
        
        // 2. High-energy alarm siren: 1.0 second loop alternating/sweeping 750 Hz - 1400 Hz
        // Rich with harmonics for maximum piercing audibility
        sirenBuffer = createSirenBuffer(duration: 1.0)
    }
    
    private func createToneBuffer(frequency: Double, duration: Double, volume: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        
        guard let channels = buffer.floatChannelData else { return nil }
        let channel = channels[0]
        let twoPi = 2.0 * Double.pi
        let fadeFrames = Int(sampleRate * 0.015) // 15ms fade in/out
        
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            var sample = sin(twoPi * frequency * t)
            
            // Soft sine envelope
            if i < fadeFrames {
                sample *= Double(i) / Double(fadeFrames)
            } else if i > Int(frameCount) - fadeFrames {
                sample *= Double(Int(frameCount) - i) / Double(fadeFrames)
            }
            channel[i] = Float(sample * volume)
        }
        return buffer
    }
    
    private func createSirenBuffer(duration: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        
        guard let channels = buffer.floatChannelData else { return nil }
        let channel = channels[0]
        let twoPi = 2.0 * Double.pi
        
        var phase: Double = 0.0
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            // Frequency sweeps up and down between 700 Hz and 1500 Hz
            let sweepFreq = 700.0 + 800.0 * (0.5 * (1.0 + sin(twoPi * 1.5 * t)))
            phase += twoPi * sweepFreq / sampleRate
            if phase > twoPi { phase -= twoPi }
            
            // Fundamental + 3rd harmonic for harsh siren piercing sound
            var sample = 0.75 * sin(phase) + 0.25 * sin(phase * 3.0)
            // Limit to [-1.0, 1.0]
            sample = max(-1.0, min(1.0, sample))
            channel[i] = Float(sample * 0.98) // Maximum amplitude
        }
        return buffer
    }
    
    // MARK: - Playback Methods
    
    /// Plays a single friendly countdown beep on built-in speakers.
    func playFriendlyCountdownBeep() {
        guard let speakerID = findBuiltInSpeakerID(),
              let buffer = countdownToneBuffer else { return }
        
        do {
            try setupEngine(targetDeviceID: speakerID)
            
            // Ensure unmuted, moderate volume for friendly countdown
            unmuteDevice(speakerID)
            if let curVol = getDeviceVolume(speakerID), curVol < 0.4 {
                setDeviceVolume(speakerID, volume: 0.5)
            }
            
            player.play()
            player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        } catch {
            print("Failed to play countdown beep: \(error)")
        }
    }
    
    /// Starts the loud alarm at MAX volume exclusively on built-in speakers.
    func startFullAlarm() {
        guard !isPlayingSiren else { return }
        guard let speakerID = findBuiltInSpeakerID(),
              let buffer = sirenBuffer else { return }
        
        isPlayingSiren = true
        
        // 1. Save original default output and speaker volume to restore later
        originalDefaultOutputID = getDefaultOutputDeviceID()
        originalSpeakerVolume = getDeviceVolume(speakerID)
        
        // 2. Switch default output to built-in speaker so ALL system audio also routes there
        setDefaultOutputDeviceID(speakerID)
        
        // 3. Force max volume and unmute
        unmuteDevice(speakerID)
        setDeviceVolume(speakerID, volume: 1.0)
        
        // 4. Setup engine and start continuous siren loop
        do {
            try setupEngine(targetDeviceID: speakerID)
            player.play()
            player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        } catch {
            print("Failed to start siren engine: \(error)")
        }
        
        // 5. Watchdog: continuously enforce MAX volume and unmute every 200ms
        // even if someone tries to press volume down or mute!
        volumeWatchdogTimer?.invalidate()
        volumeWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self, self.isPlayingSiren else { return }
            self.unmuteDevice(speakerID)
            self.setDeviceVolume(speakerID, volume: 1.0)
            if self.getDefaultOutputDeviceID() != speakerID {
                self.setDefaultOutputDeviceID(speakerID)
            }
            if !self.player.isPlaying {
                self.player.play()
            }
        }
    }
    
    /// Stops the alarm and restores previous volume and audio output device.
    func stopAlarm() {
        isPlayingSiren = false
        volumeWatchdogTimer?.invalidate()
        volumeWatchdogTimer = nil
        
        player.stop()
        if engine.isRunning {
            engine.stop()
        }
        
        guard let speakerID = findBuiltInSpeakerID() else { return }
        
        // Restore original speaker volume
        if let origVol = originalSpeakerVolume {
            setDeviceVolume(speakerID, volume: origVol)
            originalSpeakerVolume = nil
        }
        
        // Restore original default output device (e.g. AirPods/Headphones/Monitor)
        if let origDev = originalDefaultOutputID {
            setDefaultOutputDeviceID(origDev)
            originalDefaultOutputID = nil
        }
    }
    
    /// Brief siren test (plays for 1.5 seconds and stops).
    func testSiren() {
        startFullAlarm()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.stopAlarm()
        }
    }
}
