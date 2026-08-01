import AVFoundation
import Foundation
import os

/// One recorded track (microphone or system audio).
///
/// Everything is normalised to 16 kHz mono float — the format Whisper wants — and written to a
/// 16-bit WAV. Keeping the two tracks separate provides the initial speaker attribution: microphone
/// speech is treated as the user, and system-track speech as everyone else. Echo cancellation (in
/// MicrophoneCapture) and transcript deduplication handle speaker playback that leaks back into
/// the microphone.
final class AudioTrackWriter {
    static let sampleRate: Double = 16_000

    static var targetFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    /// A capture gap longer than this is treated as an interruption (a device switch stalls
    /// the source for seconds) and is filled with silence to keep the track on the timeline.
    /// Normal buffer jitter and resampler drift stay well below it.
    private static let interruptionGapThreshold: TimeInterval = 1

    private let queue: DispatchQueue
    private let file: AVAudioFile
    private var converter: AVAudioConverter
    private let target = AudioTrackWriter.targetFormat
    private let timelineStartUptime: TimeInterval
    private let onSamples: ([Float]) -> Void

    private let levelStorage = OSAllocatedUnfairLock<Float>(initialState: 0)
    private var finished = false
    private var wroteInitialPadding = false

    /// Total number of frames written, i.e. the track's length in samples at 16 kHz.
    private let frameCountStorage = OSAllocatedUnfairLock<Int64>(initialState: 0)

    var level: Float { levelStorage.withLock { $0 } }
    var duration: TimeInterval { Double(frameCountStorage.withLock { $0 }) / Self.sampleRate }

    init(
        url: URL,
        sourceFormat: AVAudioFormat,
        label: String,
        timelineStartUptime: TimeInterval,
        onSamples: @escaping ([Float]) -> Void
    ) throws {
        guard let converter = AVAudioConverter(from: sourceFormat, to: target) else {
            throw CoreAudioError("Cannot convert \(sourceFormat) to 16 kHz mono.")
        }
        self.converter = converter
        self.timelineStartUptime = timelineStartUptime
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
    func append(
        _ buffer: AVAudioPCMBuffer,
        capturedAtUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        let bufferStartUptime = capturedAtUptime - Double(buffer.frameLength) / buffer.format.sampleRate
        guard let copy = buffer.deepCopy() else { return }

        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.process(copy, bufferStartUptime: bufferStartUptime)
        }
    }

    func finish() {
        queue.sync { finished = true }
    }

    private func process(_ buffer: AVAudioPCMBuffer, bufferStartUptime: TimeInterval) {
        // The source can come back with a different format after a device switch.
        if buffer.format != converter.inputFormat {
            guard let newConverter = AVAudioConverter(from: buffer.format, to: target) else {
                Log.audio.error("Cannot convert \(buffer.format, privacy: .public) to 16 kHz mono, dropping buffer")
                return
            }
            converter = newConverter
            Log.audio.info("Track source format changed to \(buffer.format.sampleRate, privacy: .public) Hz")
        }

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

        guard let channel = output.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))

        // Keep the track aligned with the shared timeline: pad the delayed start, and pad
        // capture interruptions (the source restarting after a device switch).
        let targetPosition = max(0, bufferStartUptime - timelineStartUptime)
        if !wroteInitialPadding {
            writeSilence(duration: targetPosition)
            wroteInitialPadding = true
        } else {
            let writtenDuration = Double(frameCountStorage.withLock { $0 }) / Self.sampleRate
            let gap = targetPosition - writtenDuration
            if gap > Self.interruptionGapThreshold {
                writeSilence(duration: gap)
            }
        }
        write(samples)
    }

    private func writeSilence(duration: TimeInterval) {
        let frameCount = Int((duration * Self.sampleRate).rounded())
        guard frameCount > 0 else { return }

        Log.audio.info("Padding audio track with \(duration, privacy: .public) seconds of silence")
        var remaining = frameCount
        let blockSize = Int(Self.sampleRate)
        while remaining > 0 {
            let count = min(remaining, blockSize)
            write([Float](repeating: 0, count: count))
            remaining -= count
        }
    }

    private func write(_ samples: [Float]) {
        guard !samples.isEmpty,
              let output = AVAudioPCMBuffer(
                  pcmFormat: target,
                  frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = output.floatChannelData?[0]
        else { return }

        output.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            channel.update(from: baseAddress, count: samples.count)
        }

        do {
            try file.write(from: output)
            frameCountStorage.withLock { $0 += Int64(output.frameLength) }
        } catch {
            Log.audio.error("Write failed: \(error, privacy: .public)")
        }

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
