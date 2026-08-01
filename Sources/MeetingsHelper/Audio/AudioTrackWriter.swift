import AVFoundation
import Foundation
import os

/// One recorded track (microphone or system audio).
///
/// Everything is normalised to 16 kHz mono float — the format Whisper wants — and written to a
/// 16-bit WAV. Keeping the two tracks separate is what gives us speaker attribution for free:
/// whatever lands on the microphone track is the user, whatever lands on the system track is
/// everyone else.
final class AudioTrackWriter {
    static let sampleRate: Double = 16_000

    static var targetFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    private let queue: DispatchQueue
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let target = AudioTrackWriter.targetFormat
    private let onSamples: ([Float]) -> Void

    private let levelStorage = OSAllocatedUnfairLock<Float>(initialState: 0)
    private var finished = false

    /// Total number of frames written, i.e. the track's length in samples at 16 kHz.
    private let frameCountStorage = OSAllocatedUnfairLock<Int64>(initialState: 0)

    var level: Float { levelStorage.withLock { $0 } }
    var duration: TimeInterval { Double(frameCountStorage.withLock { $0 }) / Self.sampleRate }

    init(url: URL, sourceFormat: AVAudioFormat, label: String, onSamples: @escaping ([Float]) -> Void) throws {
        guard let converter = AVAudioConverter(from: sourceFormat, to: target) else {
            throw CoreAudioError("Cannot convert \(sourceFormat) to 16 kHz mono.")
        }
        self.converter = converter
        self.onSamples = onSamples
        self.queue = DispatchQueue(label: "com.kovalev.MeetingsHelper.writer.\(label)", qos: .userInitiated)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        self.file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Called from the capture thread. Copies the buffer, then hands it off to our own queue.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = buffer.deepCopy() else { return }

        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.process(copy)
        }
    }

    func finish() {
        queue.sync {
            finished = true
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, output.frameLength > 0 else {
            if let error { Log.audio.error("Conversion failed: \(error, privacy: .public)") }
            return
        }

        do {
            try file.write(from: output)
            frameCountStorage.withLock { $0 += Int64(output.frameLength) }
        } catch {
            Log.audio.error("Write failed: \(error, privacy: .public)")
        }

        guard let channel = output.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))

        levelStorage.withLock { $0 = Self.rms(samples) }
        onSamples(samples)
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}

extension AVAudioPCMBuffer {
    /// Core Audio hands us buffers that are only valid inside the callback.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength

        let channels = Int(format.channelCount)
        let frames = Int(frameLength)

        if let source = floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<(format.isInterleaved ? 1 : channels) {
                let count = format.isInterleaved ? frames * channels : frames
                destination[channel].update(from: source[channel], count: count)
            }
            return copy
        }

        if let source = int16ChannelData, let destination = copy.int16ChannelData {
            for channel in 0..<(format.isInterleaved ? 1 : channels) {
                let count = format.isInterleaved ? frames * channels : frames
                destination[channel].update(from: source[channel], count: count)
            }
            return copy
        }

        if let source = int32ChannelData, let destination = copy.int32ChannelData {
            for channel in 0..<(format.isInterleaved ? 1 : channels) {
                let count = format.isInterleaved ? frames * channels : frames
                destination[channel].update(from: source[channel], count: count)
            }
            return copy
        }

        return nil
    }
}
