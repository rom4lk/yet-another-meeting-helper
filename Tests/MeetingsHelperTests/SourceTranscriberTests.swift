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
}
