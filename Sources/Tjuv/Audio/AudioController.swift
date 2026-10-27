import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import os

/// Manages audio output exclusively routed to built-in laptop speakers at max volume.
/// Guarantees that alarm audio is never played through connected devices (Bluetooth, AirPods, HDMI, etc.).
final class AudioController {
    static let shared = AudioController()
    private static let log = Logger(subsystem: "com.mj0lken.tjuv", category: "audio")
    
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var sampleRate: Double = 44100.0
    
    private var originalDefaultOutputID: AudioDeviceID?
    private var originalSpeakerVolume: Float32?
    private var isPlayingSiren = false
    private var volumeWatchdogTimer: Timer?
    private var boundDeviceID: AudioDeviceID = 0
    private var isConfiguringDevice = false

    private var lidLockedBuffer: AVAudioPCMBuffer?
    private var graceDoubleBeepBuffer: AVAudioPCMBuffer?
    private var countdownToneBuffer: AVAudioPCMBuffer?
    private var sirenBuffer: AVAudioPCMBuffer?

    init() {
        setupAudioBuffers()
        setupConfigurationChangeObserver()
        prewarmBuiltInSpeakerBinding()
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

    private func setupConfigurationChangeObserver() {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            // Ignore configuration change triggered by our own kAudioOutputUnitProperty_CurrentDevice call
            if self.isConfiguringDevice { return }
            // System audio topology changed (e.g., Bluetooth headphones connected/disconnected);
            // mark binding stale and re-bind to built-in speaker in the background.
            self.boundDeviceID = 0
            self.prewarmBuiltInSpeakerBinding()
        }
    }

    /// Binds `AVAudioEngine`'s output unit to the built-in speaker at launch so that CoreAudio's
    /// asynchronous ~55ms `AVAudioEngineConfigurationChange` settles before any sound is played.
    private func prewarmBuiltInSpeakerBinding() {
        guard let speakerID = findBuiltInSpeakerID() else { return }
        ensureEngineReady(targetDeviceID: speakerID) { _ in }
    }

    private func ensureEngineReady(targetDeviceID: AudioDeviceID, completion: @escaping (Bool) -> Void) {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        if !engine.attachedNodes.contains(player) {
            engine.attach(player)
        }

        if boundDeviceID == targetDeviceID {
            do {
                if !engine.isRunning {
                    engine.connect(player, to: engine.mainMixerNode, format: format)
                    try engine.start()
                }
                completion(true)
            } catch {
                print("Failed to start pre-bound audio engine: \(error)")
                completion(false)
            }
            return
        }

        if engine.isRunning {
            engine.stop()
        }

        guard let outputUnit = engine.outputNode.audioUnit else {
            completion(false)
            return
        }

        isConfiguringDevice = true
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

        // Wait 120ms for CoreAudio HAL's asynchronous AVAudioEngineConfigurationChange to settle
        // after switching the output unit from Bluetooth/external audio to the built-in speaker.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self = self else { return }
            self.isConfiguringDevice = false
            self.boundDeviceID = targetDeviceID
            do {
                self.engine.connect(self.player, to: self.engine.mainMixerNode, format: format)
                try self.engine.start()
                completion(true)
            } catch {
                print("Failed to start audio engine after binding to speaker: \(error)")
                self.boundDeviceID = 0
                completion(false)
            }
        }
    }
    
    // MARK: - Sound Synthesis
    
    private func setupAudioBuffers() {
        // Lid-closed / Lock & Arm confirmation sound: load macOS SecurityInterface lockClosing.aif
        // normalized to full scale (with fallback to synthesized phone-lock sound).
        lidLockedBuffer = loadSystemLockSoundBuffer() ?? createPhoneLockSoundBuffer()

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
    
    /// Loads macOS's built-in mechanical lock sound (`SecurityInterface.framework/.../lockClosing.aif`),
    /// mixes to 44.1 kHz mono, and normalizes peak amplitude to 0.96 so 60% speaker volume is crisp and clear.
    private func loadSystemLockSoundBuffer() -> AVAudioPCMBuffer? {
        let candidatePaths = [
            "/System/Library/Frameworks/SecurityInterface.framework/Versions/A/Resources/lockClosing.aif",
            "/System/Library/Frameworks/SecurityInterface.framework/Versions/A/Resources/lock.aif"
        ]
        guard let targetFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            return nil
        }

        for path in candidatePaths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path),
                  let file = try? AVAudioFile(forReading: url) else { continue }

            let srcFormat = file.processingFormat
            let srcFrameCount = AVAudioFrameCount(file.length)
            guard srcFrameCount > 0,
                  let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: srcFrameCount),
                  (try? file.read(into: srcBuffer)) != nil,
                  let srcChannels = srcBuffer.floatChannelData else { continue }

            let chCount = Int(srcFormat.channelCount)
            let srcLen = Int(srcBuffer.frameLength)
            let ratio = sampleRate / srcFormat.sampleRate
            let dstLen = Int(Double(srcLen) * ratio)
            guard dstLen > 0,
                  let dstBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(dstLen)),
                  let dstChannels = dstBuffer.floatChannelData else { continue }
            dstBuffer.frameLength = AVAudioFrameCount(dstLen)
            let dst = dstChannels[0]

            var peak: Float = 0.001
            for i in 0..<dstLen {
                let srcIdx = min(Int(Double(i) / ratio), srcLen - 1)
                var mono: Float = 0
                for c in 0..<chCount {
                    mono += srcChannels[c][srcIdx]
                }
                mono /= Float(chCount)
                dst[i] = mono
                if abs(mono) > peak { peak = abs(mono) }
            }

            let gain = 0.96 / peak
            for i in 0..<dstLen {
                dst[i] *= gain
            }
            return dstBuffer
        }
        return nil
    }

    /// Synthesizes a crisp, phone-style mechanical lock sound ("click-clunk" latch transient) as a fallback.
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

    /// Plays the locking sound exclusively from the built-in speakers at 60% volume.
    func playLidLockedSound(completion: (() -> Void)? = nil) {
        guard !isPlayingSiren else {
            completion?()
            return
        }
        guard let speakerID = findBuiltInSpeakerID(),
              let buffer = lidLockedBuffer else {
            completion?()
            return
        }

        let prevVolume = getDeviceVolume(speakerID)
        unmuteDevice(speakerID)
        setDeviceVolume(speakerID, volume: 0.60)

        ensureEngineReady(targetDeviceID: speakerID) { [weak self] ready in
            guard let self = self, ready, !self.isPlayingSiren else {
                completion?()
                return
            }
            Self.log.notice("Playing lid lock sound on built-in speaker (deviceID=\(speakerID, privacy: .public), vol=0.60)")
            self.unmuteDevice(speakerID)
            self.setDeviceVolume(speakerID, volume: 0.60)
            self.player.play()
            self.player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)

            // If ThumbsOut or macOS called SACLockScreenImmediate() at the exact same millisecond,
            // coreaudiod's CMSessionIsActiveDidChange can briefly pause AVAudioEngine ~50-120ms later.
            // Check at 140ms and restart/reschedule if the engine was paused by the lock transition.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
                guard let self = self, !self.isPlayingSiren else { return }
                if !self.engine.isRunning || !self.player.isPlaying {
                    Self.log.notice("Audio engine paused by lock transition; restarting lock sound")
                    try? self.engine.start()
                    self.unmuteDevice(speakerID)
                    self.setDeviceVolume(speakerID, volume: 0.60)
                    self.player.play()
                    self.player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
                }
            }

            let durationSeconds = Double(buffer.frameLength) / self.sampleRate
            DispatchQueue.main.asyncAfter(deadline: .now() + durationSeconds + 0.18) {
                completion?()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + durationSeconds + 0.30) { [weak self] in
                guard let self = self, !self.isPlayingSiren else { return }
                if let prevVolume {
                    self.setDeviceVolume(speakerID, volume: prevVolume)
                }
            }
        }
    }

    /// Plays two short warning beeps at the start of the 3-second motion grace period.
    func playGraceWarningDoubleBeep() {
        guard !isPlayingSiren,
              let speakerID = findBuiltInSpeakerID(),
              let buffer = graceDoubleBeepBuffer else { return }

        ensureEngineReady(targetDeviceID: speakerID) { [weak self] ready in
            guard let self = self, ready, !self.isPlayingSiren else { return }
            self.unmuteDevice(speakerID)
            if let curVol = self.getDeviceVolume(speakerID), curVol < 0.45 {
                self.setDeviceVolume(speakerID, volume: 0.55)
            }
            self.player.play()
            self.player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        }
    }

    /// Plays a single friendly countdown beep on built-in speakers.
    func playFriendlyCountdownBeep() {
        guard !isPlayingSiren,
              let speakerID = findBuiltInSpeakerID(),
              let buffer = countdownToneBuffer else { return }

        ensureEngineReady(targetDeviceID: speakerID) { [weak self] ready in
            guard let self = self, ready, !self.isPlayingSiren else { return }
            self.unmuteDevice(speakerID)
            if let curVol = self.getDeviceVolume(speakerID), curVol < 0.4 {
                self.setDeviceVolume(speakerID, volume: 0.5)
            }
            self.player.play()
            self.player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
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

        // 2. Force max volume and unmute on built-in speaker
        unmuteDevice(speakerID)
        setDeviceVolume(speakerID, volume: 1.0)

        // 3. Ensure engine is bound to built-in speaker and start continuous siren loop
        ensureEngineReady(targetDeviceID: speakerID) { [weak self] ready in
            guard let self = self, ready, self.isPlayingSiren else { return }
            self.player.play()
            self.player.scheduleBuffer(buffer, at: nil, options: [.interrupts, .loops], completionHandler: nil)
        }

        // 4. Watchdog: continuously enforce MAX volume and unmute every 200ms
        volumeWatchdogTimer?.invalidate()
        volumeWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self, self.isPlayingSiren else { return }
            self.unmuteDevice(speakerID)
            self.setDeviceVolume(speakerID, volume: 1.0)
            if !self.engine.isRunning {
                try? self.engine.start()
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
