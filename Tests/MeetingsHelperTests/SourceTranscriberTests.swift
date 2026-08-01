import XCTest
@testable import MeetingsHelper

final class SourceTranscriberTests: XCTestCase {
    func testFinishDoesNotWaitForTranscriptionWhenRecognitionIsNotReady() async {
        let transcriptionStarted = expectation(description: "Transcription started")
        let transcriber = SourceTranscriber(
            source: .me,
            language: "en",
            transcribe: { _, _ in
                transcriptionStarted.fulfill()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                return "This result should be discarded."
            },
            onLine: { _ in
                XCTFail("Cancelled transcription produced a line")
            }
        )

        let speech = [Float](repeating: 0.1, count: 4 * 1_600)
        let silence = [Float](repeating: 0, count: 8 * 1_600)
        transcriber.feed(speech + silence)
        await fulfillment(of: [transcriptionStarted], timeout: 1)

        let startedAt = Date()
        await transcriber.finish(waitForTranscription: false)

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    }

    // MARK: - Echo gate

    /// Verdicts arrive on the main actor from a background task, so the test reads them under a lock.
    private final class Verdicts: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [EchoVerdict] = []

        func append(_ verdict: EchoVerdict) {
            lock.lock()
            values.append(verdict)
            lock.unlock()
        }

        var reported: [EchoVerdict] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    /// One speech-shaped burst, surrounded by enough silence for the VAD to open and close it.
    private static let burst: [Float] = [0.05, 0.10, 0.14, 0.18, 0.20, 0.16, 0.11, 0.06]
    private static let silence = [Float](repeating: 0, count: 8)

    private func samples(_ amplitudes: [Float]) -> [Float] {
        amplitudes.flatMap { [Float](repeating: $0, count: EchoReference.frameSize) }
    }

    private func reference(_ amplitudes: [Float]) -> EchoReference {
        let reference = EchoReference()
        reference.append(samples(amplitudes + [Float](repeating: 0, count: 6)))
        return reference
    }

    func testSpeakerLeakageIsNotTranscribed() async {
        let played = Self.silence + Self.burst.map { $0 * 3 } + Self.silence
        let heard = Self.silence + Self.burst.map { $0 * 0.3 } + Self.silence
        let verdicts = Verdicts()

        let transcriber = SourceTranscriber(
            source: .me,
            language: "en",
            echoReference: reference(played),
            onEchoVerdict: { verdicts.append($0) },
            transcribe: { _, _ in "Speaker playback that leaked into the microphone." },
            onLine: { line in XCTFail("Echo was transcribed: \(line.text)") }
        )

        transcriber.feed(samples(heard))
        await transcriber.finish(waitForTranscription: true)

        XCTAssertEqual(verdicts.reported, [.echo])
    }

    func testSpeechIsTranscribedWhileTheSystemIsPlaying() async {
        let recognized = expectation(description: "Speech was transcribed")
        // Quiet enough to look like leakage by level alone, but with its own envelope shape.
        let ownVoice: [Float] = [0.060, 0.048, 0.009, 0.054, 0.012, 0.057, 0.015, 0.051]
        let played = Self.silence + Self.burst.map { $0 * 3 } + Self.silence
        let heard = Self.silence + ownVoice + Self.silence
        let verdicts = Verdicts()

        let transcriber = SourceTranscriber(
            source: .me,
            language: "en",
            echoReference: reference(played),
            onEchoVerdict: { verdicts.append($0) },
            transcribe: { _, _ in "Something I said while the meeting audio was playing." },
            onLine: { _ in recognized.fulfill() }
        )

        transcriber.feed(samples(heard))
        await transcriber.finish(waitForTranscription: true)
        await fulfillment(of: [recognized], timeout: 1)

        XCTAssertEqual(verdicts.reported, [.speech])
    }

    /// With the gate off there is no reference at all, so nothing is compared and nothing waits
    /// for the system track — the utterance goes straight to recognition.
    func testUtterancesGoStraightToRecognitionWithoutAReference() async {
        let recognized = expectation(description: "Speech was transcribed")
        let verdicts = Verdicts()
        let heard = Self.silence + Self.burst.map { $0 * 0.3 } + Self.silence

        let transcriber = SourceTranscriber(
            source: .me,
            language: "en",
            echoReference: nil,
            onEchoVerdict: { verdicts.append($0) },
            transcribe: { _, _ in "Recognized without any echo check." },
            onLine: { _ in recognized.fulfill() }
        )

        let startedAt = Date()
        transcriber.feed(samples(heard))
        await transcriber.finish(waitForTranscription: true)
        await fulfillment(of: [recognized], timeout: 1)

        XCTAssertEqual(verdicts.reported, [])
        // A gated utterance waits up to 0.5 s for the system track; this one must not wait at all.
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
    }

    func testSpeechIsTranscribedWhenTheSystemTrackIsMissing() async {
        let recognized = expectation(description: "Speech was transcribed")
        let heard = Self.silence + Self.burst.map { $0 * 0.3 } + Self.silence
        let verdicts = Verdicts()

        let transcriber = SourceTranscriber(
            source: .me,
            language: "en",
            echoReference: EchoReference(),
            onEchoVerdict: { verdicts.append($0) },
            transcribe: { _, _ in "Nothing to compare against." },
            onLine: { _ in recognized.fulfill() }
        )

        transcriber.feed(samples(heard))
        await transcriber.finish(waitForTranscription: true)
        await fulfillment(of: [recognized], timeout: 1)

        XCTAssertEqual(verdicts.reported, [.undecided])
    }
}
