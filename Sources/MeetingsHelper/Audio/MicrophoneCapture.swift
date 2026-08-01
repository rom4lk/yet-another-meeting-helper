import AVFoundation
import Foundation

/// Captures the default input device via AVAudioEngine.
final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private var isRunning = false

    private(set) var format: AVAudioFormat?

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard !isRunning else { return }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CoreAudioError("Microphone unavailable: no input device is selected in the system.")
        }
        self.format = format

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            onBuffer(buffer)
        }

        engine.prepare()
        try engine.start()
        isRunning = true

        Log.audio.info("Microphone capture started at \(format.sampleRate, privacy: .public) Hz")
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }
}
