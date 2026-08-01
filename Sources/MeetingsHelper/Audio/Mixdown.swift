import AVFoundation
import Foundation

/// Mixes the two recorded tracks into a single compressed file for playback.
///
/// The separate tracks stay on disk — they are the source of truth and what the transcriber
/// used. The mixdown exists so the detail view can have one ordinary play button.
enum Mixdown {
    private static let blockSize: AVAudioFrameCount = 16_000 // 1 second

    @discardableResult
    static func create(micURL: URL?, systemURL: URL?, outputURL: URL) -> Bool {
        let inputs = [micURL, systemURL]
            .compactMap { $0 }
            .compactMap { try? AVAudioFile(forReading: $0) }
            .filter { $0.length > 0 }

        guard !inputs.isEmpty else { return false }

        let format = AudioTrackWriter.targetFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000
        ]

        do {
            let output = try AVAudioFile(forWriting: outputURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let totalFrames = inputs.map(\.length).max() ?? 0
            // Two speakers rarely peak together; halving each keeps headroom without a limiter.
            let gain: Float = inputs.count > 1 ? 0.75 : 1.0

            var position: AVAudioFramePosition = 0
            while position < totalFrames {
                let frames = AVAudioFrameCount(min(Int64(blockSize), totalFrames - position))
                guard let mixed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { break }
                mixed.frameLength = frames
                guard let destination = mixed.floatChannelData?[0] else { break }
                destination.update(repeating: 0, count: Int(frames))

                for input in inputs {
                    guard input.framePosition < input.length else { continue }
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { continue }
                    try input.read(into: buffer, frameCount: frames)
                    guard let source = buffer.floatChannelData?[0] else { continue }
                    for index in 0..<Int(buffer.frameLength) {
                        destination[index] += source[index] * gain
                    }
                }

                for index in 0..<Int(frames) {
                    destination[index] = max(-1, min(1, destination[index]))
                }

                try output.write(from: mixed)
                position += Int64(frames)
            }

            return true
        } catch {
            Log.audio.error("Mixdown failed: \(error, privacy: .public)")
            return false
        }
    }
}
