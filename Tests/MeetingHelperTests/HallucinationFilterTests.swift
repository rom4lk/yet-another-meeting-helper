import XCTest
@testable import MeetingHelper

/// The filter holds verbatim Whisper output, so the phrases below are model data rather than
/// interface text and stay in the language the model produces them in.
final class HallucinationFilterTests: XCTestCase {
    func testDropsKnownNearSilenceArtefacts() {
        XCTAssertTrue(TranscriptionEngine.isHallucination("Спасибо за просмотр!"))
        XCTAssertTrue(TranscriptionEngine.isHallucination("Thanks for watching!"))
        XCTAssertTrue(TranscriptionEngine.isHallucination("Продолжение следует..."))
        XCTAssertTrue(TranscriptionEngine.isHallucination("."))
    }

    func testMatchingIgnoresCase() {
        XCTAssertTrue(TranscriptionEngine.isHallucination("THANK YOU."))
        XCTAssertTrue(TranscriptionEngine.isHallucination("СПАСИБО ЗА ВНИМАНИЕ!"))
    }

    func testKeepsRealSpeech() {
        XCTAssertFalse(TranscriptionEngine.isHallucination("Thank you for the detailed answer."))
        XCTAssertFalse(TranscriptionEngine.isHallucination("Спасибо, я посмотрю документ завтра."))
        XCTAssertFalse(TranscriptionEngine.isHallucination("You should send the report."))
    }

    func testMatchesWholePhrasesOnly() {
        // "you" alone is an artefact; the same word inside a sentence is not.
        XCTAssertTrue(TranscriptionEngine.isHallucination("you"))
        XCTAssertFalse(TranscriptionEngine.isHallucination("you were right"))
    }
}
