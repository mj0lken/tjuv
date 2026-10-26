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
    
    private var lidLockedBuffer: AVAudioPCMBuffer?
    private var graceDoubleBeepBuffer: AVAudioPCMBuffer?
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
        // Lid-closed locking confirmation sound (mechanical phone-lock "click-clunk")
        lidLockedBuffer = createPhoneLockSoundBuffer()

        // 0. Two short grace-period warning beeps ("put laptop down within 3s")
        graceDoubleBeepBuffer = createDoubleBeepBuffer(
            freq1: 987.77,
            dur1: 0.085,
            gap: 0.070,
            freq2: 1318.51,
            dur2: 0.100,
            volume: 0.55
        )

        // 1. Friendly countdown beep: 1000 Hz, 120ms with pleasant fade envelope
        countdownToneBuffer = createToneBuffer(frequency: 1046.5, duration: 0.12, volume: 0.45)
        
        // 2. High-energy alarm siren: 1.0 second loop alternating/sweeping 750 Hz - 1400 Hz
        // Rich with harmonics for maximum piercing audibility
        sirenBuffer = createSirenBuffer(duration: 1.0)
    }

    private func createDoubleBeepBuffer(
        freq1: Double,
        dur1: Double,
        gap: Double,
        freq2: Double,
        dur2: Double,
        volume: Double
    ) -> AVAudioPCMBuffer? {
        let totalDuration = dur1 + gap + dur2
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
        let frameCount = AVAudioFrameCount(sampleRate * totalDuration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        guard let channels = buffer.floatChannelData else { return nil }
        let channel = channels[0]
        let twoPi = 2.0 * Double.pi
        let fadeFrames = Int(sampleRate * 0.010)
        let beep1End = Int(sampleRate * dur1)
        let beep2Start = Int(sampleRate * (dur1 + gap))
        let beep2End = Int(frameCount)

        for i in 0..<Int(frameCount) {
            if i < beep1End {
                let t = Double(i) / sampleRate
                var sample = sin(twoPi * freq1 * t)
                if i < fadeFrames {
                    sample *= Double(i) / Double(fadeFrames)
                } else if i > beep1End - fadeFrames {
                    sample *= Double(beep1End - i) / Double(fadeFrames)
                }
                channel[i] = Float(sample * volume)
            } else if i >= beep2Start && i < beep2End {
                let localIdx = i - beep2Start
                let localLen = beep2End - beep2Start
                let t = Double(localIdx) / sampleRate
                var sample = sin(twoPi * freq2 * t)
                if localIdx < fadeFrames {
                    sample *= Double(localIdx) / Double(fadeFrames)
                } else if localIdx > localLen - fadeFrames {
                    sample *= Double(localLen - localIdx) / Double(fadeFrames)
                }
                channel[i] = Float(sample * volume)
            } else {
                channel[i] = 0.0
            }
        }
        return buffer
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
    
    /// Synthesizes a crisp, phone-style mechanical lock sound ("click-clunk" latch transient).
    private func createPhoneLockSoundBuffer() -> AVAudioPCMBuffer? {
        let duration = 0.15
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        guard let channels = buffer.floatChannelData else { return nil }
        let channel = channels[0]
        let twoPi = 2.0 * Double.pi
        let secondClickOnset = 0.033

        var rngState: UInt64 = 0x9E3779B97F4A7C15
        let nextNoise: () -> Double = {
            rngState ^= rngState >> 12
            rngState ^= rngState << 25
            rngState ^= rngState >> 27
            let val = rngState &* 0x2545F4914F6CDD1D
            return (Double(val & 0xFFFFFF) / Double(0x800000)) - 1.0
        }

        var rawSamples = [Double](repeating: 0.0, count: Int(frameCount))
        var peak = 0.001
        var phase1 = 0.0
        var phase2 = 0.0

        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let noise = nextNoise()
            var sample = 0.0

            // 1. Upper latch click at t = 0.000s (crisp high snap)
            let envClick1 = exp(-t / 0.0016)
            let f1 = 360.0 + 380.0 * exp(-t / 0.003)
            phase1 += twoPi * f1 / sampleRate
            let snap1 = 0.55 * noise * envClick1
                + 0.65 * sin(twoPi * 2250.0 * t) * exp(-t / 0.0032)
                + 0.45 * sin(twoPi * 3550.0 * t) * exp(-t / 0.0020)
                + 0.45 * sin(phase1) * exp(-t / 0.0045)
            sample += snap1 * 0.68

            // 2. Main deadbolt seating "clunk" at t = 0.033s (deeper mechanical body + crisp lock snap)
            if t >= secondClickOnset {
                let t2 = t - secondClickOnset
                let envImpact2 = exp(-t2 / 0.0019)
                let f2 = 145.0 + 310.0 * exp(-t2 / 0.0065)
                phase2 += twoPi * f2 / sampleRate
                let bodyThud = 0.95 * sin(phase2) * exp(-t2 / 0.013)
                let modalResonance = 0.70 * sin(twoPi * 1420.0 * t2) * exp(-t2 / 0.0050)
                    + 0.55 * sin(twoPi * 2580.0 * t2) * exp(-t2 / 0.0034)
                    + 0.30 * sin(twoPi * 4100.0 * t2) * exp(-t2 / 0.0022)
                let contactNoise = 0.65 * noise * envImpact2
                sample += bodyThud + modalResonance + contactNoise
            }

            rawSamples[i] = sample
            if abs(sample) > peak { peak = abs(sample) }
        }

        let norm = 0.98 / peak
        for i in 0..<Int(frameCount) {
            channel[i] = Float(rawSamples[i] * norm)
        }
        return buffer
    }

    // MARK: - Playback Methods

    /// Plays a phone-style locking sound exclusively from the built-in speakers at 60% volume.
    func playLidLockedSound() {
        guard !isPlayingSiren else { return }
        guard let speakerID = findBuiltInSpeakerID(),
              let buffer = lidLockedBuffer else { return }

        let prevOutputID = getDefaultOutputDeviceID()
        let prevVolume = getDeviceVolume(speakerID)

        do {
            setDefaultOutputDeviceID(speakerID)
            unmuteDevice(speakerID)
            setDeviceVolume(speakerID, volume: 0.60)

            try setupEngine(targetDeviceID: speakerID)
            player.play()
            player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
                guard let self = self, !self.isPlayingSiren else { return }
                if let prevVolume {
                    self.setDeviceVolume(speakerID, volume: prevVolume)
                }
                if let prevOutputID, prevOutputID != speakerID {
                    self.setDefaultOutputDeviceID(prevOutputID)
                }
            }
        } catch {
            print("Failed to play lid lock sound: \(error)")
        }
    }

    /// Plays two short warning beeps at the start of the 3-second motion grace period.
    func playGraceWarningDoubleBeep() {
        guard let speakerID = findBuiltInSpeakerID(),
              let buffer = graceDoubleBeepBuffer else { return }

        do {
            try setupEngine(targetDeviceID: speakerID)
            unmuteDevice(speakerID)
            if let curVol = getDeviceVolume(speakerID), curVol < 0.45 {
                setDeviceVolume(speakerID, volume: 0.55)
            }
            player.play()
            player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        } catch {
            print("Failed to play grace warning double beep: \(error)")
        }
    }
    
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
