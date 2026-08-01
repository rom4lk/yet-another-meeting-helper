import AVFoundation
import Foundation

/// Captures the default input device through a plain AVAudioEngine tap.
///
/// The engine stops itself whenever the input device changes (headphones connect, the default
/// device switches) and never restarts on its own, so a configuration-change observer restarts it.
final class MicrophoneCapture {
    private var engine: AVAudioEngine?
    private var configurationChangeObserver: (any NSObjectProtocol)?
    private var restartScheduled = false
    private var restartGeneration = 0

    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var isRunning = false

    private(set) var format: AVAudioFormat?

    deinit {
        stop()
    }

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard !isRunning else { return }
        self.onBuffer = onBuffer

        try startEngine(onBuffer: onBuffer)
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        restartGeneration += 1
        restartScheduled = false

        stopEngine()
        onBuffer = nil
    }

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

        Log.audio.info("Microphone capture started at \(format.sampleRate, privacy: .public) Hz")
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
