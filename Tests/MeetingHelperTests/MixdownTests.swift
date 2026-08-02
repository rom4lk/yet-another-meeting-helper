import AVFoundation
import XCTest
@testable import MeetingHelper

final class MixdownTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MixdownTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testProducesNothingWithoutInputs() {
        let output = directory.appendingPathComponent("mix.m4a")

        XCTAssertFalse(Mixdown.create(micURL: nil, systemURL: nil, outputURL: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testProducesNothingWhenTheTracksAreMissingFromDisk() {
        let output = directory.appendingPathComponent("mix.m4a")

        XCTAssertFalse(Mixdown.create(
            micURL: directory.appendingPathComponent("absent-mic.wav"),
            systemURL: directory.appendingPathComponent("absent-system.wav"),
            outputURL: output
        ))
    }

    func testSingleTrackKeepsItsLength() throws {
        let mic = try writeTone(named: "mic.wav", seconds: 2, amplitude: 0.4)
        let output = directory.appendingPathComponent("mix.m4a")

        XCTAssertTrue(Mixdown.create(micURL: mic, systemURL: nil, outputURL: output))

        XCTAssertEqual(try duration(of: output), 2, accuracy: 0.2)
    }

    func testMixSpansTheLongerOfTheTwoTracks() throws {
        let mic = try writeTone(named: "mic.wav", seconds: 1, amplitude: 0.4)
        let system = try writeTone(named: "system.wav", seconds: 3, amplitude: 0.4)
        let output = directory.appendingPathComponent("mix.m4a")

        XCTAssertTrue(Mixdown.create(micURL: mic, systemURL: system, outputURL: output))

        XCTAssertEqual(try duration(of: output), 3, accuracy: 0.2)
    }

    /// The per-track gain exists so two people talking at once still fit in range without a
    /// limiter. Two loud speakers sum to 0.9 at that gain, which must not need clipping at all.
    func testTwoLoudTracksMixWithoutClipping() throws {
        let mic = try writeTone(named: "mic.wav", seconds: 1, amplitude: 0.6)
        let system = try writeTone(named: "system.wav", seconds: 1, amplitude: 0.6)
        let output = directory.appendingPathComponent("mix.m4a")

        XCTAssertTrue(Mixdown.create(micURL: mic, systemURL: system, outputURL: output))

        XCTAssertLessThanOrEqual(try peakAmplitude(of: output), 1.0)
    }

    /// Full-scale material does clip, and the clamp has to saturate it rather than let it wrap
    /// around into the opposite sign. The bound is loose because AAC overshoots a hard-clipped
    /// waveform by around a decibel; a wrap would show up as a value far past that.
    func testClippedMixSaturatesInsteadOfWrapping() throws {
        let mic = try writeTone(named: "mic.wav", seconds: 1, amplitude: 1.0)
        let system = try writeTone(named: "system.wav", seconds: 1, amplitude: 1.0)
        let output = directory.appendingPathComponent("mix.m4a")

        XCTAssertTrue(Mixdown.create(micURL: mic, systemURL: system, outputURL: output))

        XCTAssertLessThanOrEqual(try peakAmplitude(of: output), 1.2)
    }

    // MARK: - Helpers

    private func writeTone(named name: String, seconds: Double, amplitude: Float) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let format = AudioTrackWriter.targetFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) {
            // A 220 Hz tone: real content, so the encoder has something to preserve.
            channel[index] = amplitude * sin(2 * .pi * 220 * Float(index) / Float(format.sampleRate))
        }
        try file.write(from: buffer)
        return url
    }

    private func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private func peakAmplitude(of url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            )
        )
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        var peak: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            peak = max(peak, abs(channel[index]))
        }
        return peak
    }
}
