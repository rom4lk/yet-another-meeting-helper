import AVFoundation
import XCTest
@testable import MeetingHelper

/// The writer hands samples to its callback from its own queue, so the tests count them behind
/// a lock rather than mutating a captured variable.
private final class SampleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0

    func add(_ count: Int) {
        lock.lock()
        total += count
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return total
    }
}

final class AudioTrackWriterTests: XCTestCase {
    func testPadsTrackToSharedTimeline() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let format = AudioTrackWriter.targetFormat
        let inputFrameCount = 1_600
        let input = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(inputFrameCount)
            )
        )
        input.frameLength = AVAudioFrameCount(inputFrameCount)
        let channel = try XCTUnwrap(input.floatChannelData?[0])
        channel.update(repeating: 0.25, count: inputFrameCount)

        let timelineSampleCount = SampleCounter()
        var writer: AudioTrackWriter? = try AudioTrackWriter(
            url: outputURL,
            sourceFormat: format,
            label: "timeline-test",
            timelineStartUptime: 100,
            onSamples: { timelineSampleCount.add($0.count) }
        )

        writer?.append(input, capturedAtUptime: 101.1)
        writer?.finish()
        let duration = try XCTUnwrap(writer).duration
        writer = nil

        let file = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(file.length, 17_600)
        XCTAssertEqual(timelineSampleCount.value, 17_600)
        XCTAssertEqual(duration, 1.1, accuracy: 0.001)
    }

    func testPadsCaptureInterruption() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let format = AudioTrackWriter.targetFormat
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        input.frameLength = 1_600
        try XCTUnwrap(input.floatChannelData?[0]).update(repeating: 0.25, count: 1_600)

        var writer: AudioTrackWriter? = try AudioTrackWriter(
            url: outputURL,
            sourceFormat: format,
            label: "gap-test",
            timelineStartUptime: 100,
            onSamples: { _ in }
        )

        // 0.1 s of audio starting right at the timeline start, then the source stalls for
        // 3.9 s (a device switch) and comes back.
        writer?.append(input, capturedAtUptime: 100.1)
        writer?.append(input, capturedAtUptime: 104.1)
        writer?.finish()
        let duration = try XCTUnwrap(writer).duration
        writer = nil

        // 0.1 s + 3.9 s of silence + 0.1 s = 4.1 s.
        let file = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(file.length, 65_600)
        XCTAssertEqual(duration, 4.1, accuracy: 0.001)
    }

    /// The capture callbacks hold the writer for as long as Core Audio holds their blocks, so the
    /// track has to be complete when `finish()` returns rather than when the writer is released.
    func testTrackIsReadableWhileTheWriterIsStillAlive() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let format = AudioTrackWriter.targetFormat
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        input.frameLength = 1_600
        try XCTUnwrap(input.floatChannelData?[0]).update(repeating: 0.25, count: 1_600)

        let writer = try AudioTrackWriter(
            url: outputURL,
            sourceFormat: format,
            label: "close-test",
            timelineStartUptime: 100,
            onSamples: { _ in }
        )

        writer.append(input, capturedAtUptime: 100.1)
        writer.finish()

        let file = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(file.length, 1_600)
        withExtendedLifetime(writer) {}
    }

    func testConvertsBuffersAfterFormatChange() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let monoFormat = AudioTrackWriter.targetFormat
        let mono = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 1_600))
        mono.frameLength = 1_600
        try XCTUnwrap(mono.floatChannelData?[0]).update(repeating: 0.25, count: 1_600)

        // Same rate, different channel count — a new input device delivering stereo.
        let stereoFormat = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 2, interleaved: false)
        )
        let stereo = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 1_600))
        stereo.frameLength = 1_600
        try XCTUnwrap(stereo.floatChannelData?[0]).update(repeating: 0.25, count: 1_600)
        try XCTUnwrap(stereo.floatChannelData?[1]).update(repeating: 0.25, count: 1_600)

        let sampleCount = SampleCounter()
        var writer: AudioTrackWriter? = try AudioTrackWriter(
            url: outputURL,
            sourceFormat: monoFormat,
            label: "format-test",
            timelineStartUptime: 100,
            onSamples: { sampleCount.add($0.count) }
        )

        writer?.append(mono, capturedAtUptime: 100.1)
        writer?.append(stereo, capturedAtUptime: 100.2)
        writer?.finish()
        let duration = try XCTUnwrap(writer).duration
        writer = nil

        let file = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(file.length, 3_200)
        XCTAssertEqual(sampleCount.value, 3_200)
        XCTAssertEqual(duration, 0.2, accuracy: 0.001)
    }
}
