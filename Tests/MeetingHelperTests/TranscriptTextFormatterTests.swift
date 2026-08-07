import XCTest
@testable import MeetingHelper

@MainActor
final class TranscriptTextFormatterTests: XCTestCase {
    private let lines = [
        TranscriptLine(source: .me, offset: 1.5, text: "Can you hear me?"),
        TranscriptLine(source: .others, offset: 3, text: "Loud and clear.")
    ]

    func testIncludesTheTranscriptionModel() {
        XCTAssertEqual(
            TranscriptTextFormatter.string(
                from: lines,
                transcriptionModel: "openai_whisper-large-v3"
            ),
            """
            Transcription model: Whisper large-v3

            [00:01] Me: Can you hear me?
            [00:03] Others: Loud and clear.
            """
        )
    }

    func testLegacyMeetingWithoutAModelKeepsTheExistingFormat() {
        XCTAssertEqual(
            TranscriptTextFormatter.string(from: lines, transcriptionModel: nil),
            """
            [00:01] Me: Can you hear me?
            [00:03] Others: Loud and clear.
            """
        )
    }
}
