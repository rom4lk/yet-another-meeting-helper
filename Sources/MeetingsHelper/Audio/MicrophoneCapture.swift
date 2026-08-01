import AVFoundation
import AudioToolbox
import Foundation

/// Captures the default input device.
///
/// With `voiceProcessing` the microphone is read from the system voice-processing unit
/// (AUVoiceIO) driven directly through the C API. The unit subtracts whatever the Mac is
/// playing from the captured signal — the playback reference, device latencies and clock
/// drift are all handled inside Core Audio — and it runs on an aggregate of the default
/// input and output devices that follows device switches on its own. AVAudioEngine's
/// voice-processing wrapper is deliberately not used: on macOS an input-only engine with
/// voice processing enabled never delivers input buffers, and pulling the output node into
/// the graph fails to initialize.
///
/// Without voice processing the input runs through a plain AVAudioEngine tap. The engine
/// stops itself whenever the input device changes (headphones connect, the default device
/// switches) and never restarts on its own, so a configuration-change observer restarts it.
final class MicrophoneCapture {
    private struct DefaultOutputRoute {
        let outputDevice: AudioDeviceID?
        let systemOutputDevice: AudioDeviceID?

        static func capture() -> DefaultOutputRoute {
            DefaultOutputRoute(
                outputDevice: try? AudioObjectID.readDefaultOutputDevice(),
                systemOutputDevice: try? AudioObjectID.readDefaultSystemOutputDevice()
            )
        }

        func restore() {
            restore(
                outputDevice,
                current: AudioObjectID.readDefaultOutputDevice,
                set: AudioObjectID.setDefaultOutputDevice,
                label: "default output"
            )
            restore(
                systemOutputDevice,
                current: AudioObjectID.readDefaultSystemOutputDevice,
                set: AudioObjectID.setDefaultSystemOutputDevice,
                label: "system output"
            )
        }

        private func restore(
            _ deviceID: AudioDeviceID?,
            current: () throws -> AudioDeviceID,
            set: (AudioDeviceID) throws -> Void,
            label: String
        ) {
            guard let deviceID, deviceID.isValid else { return }

            do {
                guard try current() != deviceID else { return }
                try set(deviceID)
                Log.audio.info("Restored the \(label, privacy: .public) device after voice processing stopped")
            } catch {
                Log.audio.error("Could not restore the \(label, privacy: .public) device: \(error, privacy: .public)")
            }
        }
    }

    /// Everything the voice-processing render callbacks need. Kept alive by the capture
    /// object for as long as the unit exists.
    fileprivate final class VoiceProcessingContext {
        var unit: AudioUnit?
        let format: AVAudioFormat
        let onBuffer: (AVAudioPCMBuffer) -> Void

        init(format: AVAudioFormat, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
            self.format = format
            self.onBuffer = onBuffer
        }
    }

    private var engine: AVAudioEngine?
    private var configurationChangeObserver: (any NSObjectProtocol)?
    private var restartScheduled = false
    private var restartGeneration = 0

    private var voiceProcessingUnit: AudioUnit?
    private var voiceProcessingContext: VoiceProcessingContext?

    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var isRunning = false

    private(set) var format: AVAudioFormat?

    deinit {
        stop()
    }

    func start(voiceProcessing: Bool, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard !isRunning else { return }
        self.onBuffer = onBuffer

        if voiceProcessing {
            do {
                try startVoiceProcessingUnit(onBuffer: onBuffer)
                isRunning = true
                return
            } catch {
                Log.audio.error("Voice processing unavailable, capturing raw microphone: \(error, privacy: .public)")
            }
        }

        try startEngine(onBuffer: onBuffer)
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        restartGeneration += 1
        restartScheduled = false

        stopEngine()
        if let unit = voiceProcessingUnit {
            // VoiceProcessingIO owns a duplex route. Releasing it can make macOS promote the
            // built-in speaker to the default output, especially after using Bluetooth audio.
            // Capture the route at stop time so user-initiated device changes are preserved.
            let outputRoute = DefaultOutputRoute.capture()
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            voiceProcessingUnit = nil
            voiceProcessingContext = nil
            outputRoute.restore()
        }
        onBuffer = nil
    }

    // MARK: - Voice processing (AUVoiceIO)

    private func startVoiceProcessingUnit(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CoreAudioError("The voice-processing audio unit is not available.")
        }

        var createdUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &createdUnit), "create the voice-processing unit")
        guard let unit = createdUnit else {
            throw CoreAudioError("The voice-processing unit was not created.")
        }

        do {
            var enabled: UInt32 = 1
            let flagSize = UInt32(MemoryLayout<UInt32>.size)
            try check(
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled, flagSize),
                "enable capture on the voice-processing unit"
            )
            try check(
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enabled, flagSize),
                "enable playback on the voice-processing unit"
            )

            // A fixed client format on both elements: the unit resamples from the hardware
            // internally, so device switches never change what the rest of the app sees.
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: AudioTrackWriter.sampleRate,
                channels: 1,
                interleaved: true
            ) else {
                throw CoreAudioError("Could not build the capture format.")
            }
            var asbd = format.streamDescription.pointee
            let asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(
                AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd, asbdSize),
                "set the capture format"
            )
            var outputASBD = format.streamDescription.pointee
            try check(
                AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &outputASBD, asbdSize),
                "set the playback format"
            )

            // Keep the recorded voice level untouched and do not duck the meeting audio the
            // user is listening to. Neither failure is worth losing the echo canceller over.
            var agcEnabled: UInt32 = 0
            if AudioUnitSetProperty(unit, kAUVoiceIOProperty_VoiceProcessingEnableAGC, kAudioUnitScope_Global, 0, &agcEnabled, flagSize) != noErr {
                Log.audio.error("Could not disable AGC on the voice-processing unit")
            }
            var ducking = AUVoiceIOOtherAudioDuckingConfiguration(
                mEnableAdvancedDucking: false,
                mDuckingLevel: .min
            )
            if AudioUnitSetProperty(
                unit,
                kAUVoiceIOProperty_OtherAudioDuckingConfiguration,
                kAudioUnitScope_Global,
                0,
                &ducking,
                UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size)
            ) != noErr {
                Log.audio.error("Could not minimize ducking on the voice-processing unit")
            }

            let context = VoiceProcessingContext(format: format, onBuffer: onBuffer)
            let refCon = UnsafeMutableRawPointer(Unmanaged.passUnretained(context).toOpaque())
            let callbackSize = UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            var inputCallback = AURenderCallbackStruct(inputProc: voiceProcessingInputCallback, inputProcRefCon: refCon)
            try check(
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &inputCallback, callbackSize),
                "install the capture callback"
            )
            var renderCallback = AURenderCallbackStruct(inputProc: voiceProcessingSilenceCallback, inputProcRefCon: nil)
            try check(
                AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &renderCallback, callbackSize),
                "install the playback callback"
            )

            try check(AudioUnitInitialize(unit), "initialize the voice-processing unit")
            context.unit = unit
            // The context must outlive the unit: callbacks hold an unretained pointer to it.
            voiceProcessingContext = context
            try check(AudioOutputUnitStart(unit), "start the voice-processing unit")

            voiceProcessingUnit = unit
            self.format = format
            Log.audio.info("Microphone capture started through the voice-processing unit at \(format.sampleRate, privacy: .public) Hz")
        } catch {
            voiceProcessingContext = nil
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status != noErr else { return }
        throw CoreAudioError("Could not \(operation) (error \(status)).")
    }

    // MARK: - Raw capture (AVAudioEngine)

    private func startEngine(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let engine = AVAudioEngine()
        try attachTap(to: engine, onBuffer: onBuffer)
        self.engine = engine

        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleEngineRestart(after: 0.3)
        }
    }

    private func attachTap(to engine: AVAudioEngine, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CoreAudioError("Microphone unavailable: no input device is selected in the system.")
        }
        self.format = format

        // Let Core Audio select the input node's current native format. Passing the format
        // read immediately before a device switch can raise an Objective-C exception inside
        // AVAudioIONodeImpl::SetOutputFormat, which Swift error handling cannot catch.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            onBuffer(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            throw error
        }

        Log.audio.info("Microphone capture started at \(format.sampleRate, privacy: .public) Hz (raw)")
    }

    /// A device switch produces a burst of configuration-change notifications, so coalesce
    /// them into one restart.
    private func scheduleEngineRestart(after delay: TimeInterval) {
        guard isRunning, !restartScheduled else { return }
        restartScheduled = true
        let generation = restartGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isRunning, self.restartGeneration == generation else { return }
            self.restartEngine()
        }
    }

    private func restartEngine() {
        restartScheduled = false
        guard isRunning, let onBuffer else { return }

        stopEngine()
        do {
            try startEngine(onBuffer: onBuffer)
            Log.audio.info("Microphone capture restarted after a device change")
        } catch {
            Log.audio.error("Microphone restart failed, retrying: \(error, privacy: .public)")
            scheduleEngineRestart(after: 1)
        }
    }

    private func stopEngine() {
        if let observer = configurationChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationChangeObserver = nil
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
    }
}

// MARK: - Render callbacks

/// Pulls one echo-cancelled buffer out of the unit. Runs on the audio thread; the refCon is
/// an unretained `VoiceProcessingContext` kept alive by `MicrophoneCapture`.
private func voiceProcessingInputCallback(
    refCon: UnsafeMutableRawPointer,
    actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    timestamp: UnsafePointer<AudioTimeStamp>,
    busNumber: UInt32,
    frameCount: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let context = Unmanaged<MicrophoneCapture.VoiceProcessingContext>.fromOpaque(refCon).takeUnretainedValue()
    guard let unit = context.unit,
          let buffer = AVAudioPCMBuffer(pcmFormat: context.format, frameCapacity: frameCount)
    else { return noErr }

    buffer.frameLength = frameCount
    let status = AudioUnitRender(unit, actionFlags, timestamp, busNumber, frameCount, buffer.mutableAudioBufferList)
    guard status == noErr else { return status }

    context.onBuffer(buffer)
    return noErr
}

/// The unit's output side has to render something; give it silence.
private func voiceProcessingSilenceCallback(
    refCon: UnsafeMutableRawPointer,
    actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    timestamp: UnsafePointer<AudioTimeStamp>,
    busNumber: UInt32,
    frameCount: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    if let ioData {
        for buffer in UnsafeMutableAudioBufferListPointer(ioData) {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
    }
    actionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
    return noErr
}
