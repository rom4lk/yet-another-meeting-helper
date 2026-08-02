import XCTest
@testable import MeetingHelper

final class SourceTranscriberTests: XCTestCase {
    private final class RecognitionCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var sampleCounts: [Int] = []

        func response(for samples: [Float]) -> String {
            lock.lock()
            sampleCounts.append(samples.count)
            let call = sampleCounts.count
            lock.unlock()
            return call < 3 ? "Preview \(call)" : "Final result"
        }

        var counts: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return sampleCounts
        }
    }

    private final class TranscriptUpdates: @unchecked Sendable {
        private let lock = NSLock()
        private var previewLines: [TranscriptLine] = []
        private var finalLines: [TranscriptLine] = []

        func append(_ update: SourceTranscriptionUpdate) {
            lock.lock()
            defer { lock.unlock() }
            switch update {
            case .preview(let line):
                previewLines.append(line)
            case .final(let line):
                finalLines.append(line)
            case .removePreview:
                break
            }
        }

        var previews: [TranscriptLine] {
            lock.lock()
            defer { lock.unlock() }
            return previewLines
        }

        var finals: [TranscriptLine] {
            lock.lock()
            defer { lock.unlock() }
            return finalLines
        }
    }

    func testRealtimeModeUpdatesOnePreviewAndReplacesItWithTheFinalLine() async {
        let firstPreview = expectation(description: "First preview")
        let secondPreview = expectation(description: "Second preview")
        let final = expectation(description: "Final result")
        let calls = RecognitionCalls()
        let updates = TranscriptUpdates()

        let transcriber = SourceTranscriber(
            source: .others,
            language: "en",
            realtimeUpdatesEnabled: true,
            transcribe: { samples, _ in calls.response(for: samples) },
            onUpdate: { update in
                updates.append(update)
                switch update {
                case .preview:
                    if updates.previews.count == 1 {
                        firstPreview.fulfill()
                    } else {
                        secondPreview.fulfill()
                    }
                case .final:
                    final.fulfill()
                case .removePreview:
                    break
                }
            }
        )

        let twoSecondsOfSpeech = [Float](repeating: 0.1, count: 20 * EchoReference.frameSize)
        transcriber.feed(twoSecondsOfSpeech)
        await fulfillment(of: [firstPreview], timeout: 1)

        transcriber.feed(twoSecondsOfSpeech)
        await fulfillment(of: [secondPreview], timeout: 1)

        transcriber.feed([Float](repeating: 0, count: 8 * EchoReference.frameSize))
        await transcriber.finish(waitForTranscription: true)
        await fulfillment(of: [final], timeout: 1)

        let previews = updates.previews
        let finalLines = updates.finals
        XCTAssertEqual(previews.map(\.text), ["Preview 1", "Preview 2"])
        XCTAssertEqual(finalLines.map(\.text), ["Final result"])
        XCTAssertEqual(Set((previews + finalLines).map(\.id)).count, 1)
        XCTAssertEqual(calls.counts, [20, 40, 48].map { $0 * EchoReference.frameSize })
    }

    func testDisabledRealtimeModeOnlyTranscribesTheFinalUtterance() async {
        let recognized = expectation(description: "Final result")
        let calls = RecognitionCalls()
        let speech = [Float](repeating: 0.1, count: 40 * EchoReference.frameSize)
        let silence = [Float](repeating: 0, count: 8 * EchoReference.frameSize)

        let transcriber = makeTranscriber(
            source: .others,
            language: "en",
            realtimeUpdatesEnabled: false,
            transcribe: { samples, _ in calls.response(for: samples) },
            onLine: { _ in recognized.fulfill() }
        )

        transcriber.feed(speech + silence)
        await transcriber.finish(waitForTranscription: true)
        await fulfillment(of: [recognized], timeout: 1)

        XCTAssertEqual(calls.counts, [48 * EchoReference.frameSize])
    }

    func testFinishDoesNotWaitForTranscriptionWhenRecognitionIsNotReady() async {
        let transcriptionStarted = expectation(description: "Transcription started")
        let transcriber = makeTranscriber(
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

        let transcriber = makeTranscriber(
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

        let transcriber = makeTranscriber(
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

        let transcriber = makeTranscriber(
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

        let transcriber = makeTranscriber(
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

    // MARK: - Helpers

    /// The transcriber reports through a single `onUpdate` stream; several tests below only care
    /// about finished lines, so they go through this wrapper instead of a second initializer.
    private func makeTranscriber(
        source: TranscriptSource,
        language: String?,
        realtimeUpdatesEnabled: Bool = false,
        echoReference: EchoReference? = nil,
        onEchoVerdict: (@MainActor (EchoVerdict) -> Void)? = nil,
        transcribe: @escaping @Sendable ([Float], String?) async -> String?,
        onLine: @escaping @MainActor (TranscriptLine) -> Void
    ) -> SourceTranscriber {
        SourceTranscriber(
            source: source,
            language: language,
            realtimeUpdatesEnabled: realtimeUpdatesEnabled,
            echoReference: echoReference,
            onEchoVerdict: onEchoVerdict,
            transcribe: transcribe,
            onUpdate: { update in
                guard case .final(let line) = update else { return }
                onLine(line)
            }
        )
    }
}

