import XCTest
@testable import MeetingHelper

@MainActor
final class MeetingDetectorTests: XCTestCase {

    // MARK: - Title cleanup

    func testStripsBrowserNameWithHyphenSeparator() {
        XCTAssertEqual(
            MeetingDetector.cleanMeetTitle("Weekly sync - Google Chrome"),
            "Weekly sync"
        )
        XCTAssertEqual(
            MeetingDetector.cleanMeetTitle("Weekly sync - Safari"),
            "Weekly sync"
        )
    }

    func testStripsBrowserNameWithDashSeparators() {
        XCTAssertEqual(
            MeetingDetector.cleanMeetTitle("Weekly sync — Google Chrome"),
            "Weekly sync"
        )
        XCTAssertEqual(
            MeetingDetector.cleanMeetTitle("Weekly sync — Arc"),
            "Weekly sync"
        )
        XCTAssertEqual(
            MeetingDetector.cleanMeetTitle("Weekly sync – Microsoft Edge"),
            "Weekly sync"
        )
    }

    /// Edge has been seen putting a zero-width space inside its own name. The old hardcoded
    /// suffix carried that character, so a plain title never matched and the suffix stayed.
    func testStripsBrowserNameContainingAZeroWidthSpace() {
        XCTAssertEqual(
            MeetingDetector.cleanMeetTitle("Weekly sync - Microsoft\u{200B} Edge"),
            "Weekly sync"
        )
        XCTAssertEqual(
            MeetingDetector.cleanMeetTitle("Weekly sync - Microsoft Edge"),
            "Weekly sync"
        )
    }

    func testKeepsTitlesThatDoNotEndWithABrowserName() {
        XCTAssertEqual(
            MeetingDetector.cleanMeetTitle("Meet - abc-defg-hij"),
            "Meet - abc-defg-hij"
        )
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(MeetingDetector.cleanMeetTitle("  Weekly sync  "), "Weekly sync")
    }

    // MARK: - Google Meet recognition

    func testRecognizesTitlesNamingGoogleMeet() {
        XCTAssertTrue(MeetingDetector.looksLikeGoogleMeet("Design review - Google Meet"))
        XCTAssertTrue(MeetingDetector.looksLikeGoogleMeet("google meet"))
    }

    func testRecognizesTitlesCarryingAMeetingCode() {
        XCTAssertTrue(MeetingDetector.looksLikeGoogleMeet("Meet — abc-defg-hij"))
    }

    func testRejectsUnrelatedTitles() {
        XCTAssertFalse(MeetingDetector.looksLikeGoogleMeet("Inbox — Gmail"))
        XCTAssertFalse(MeetingDetector.looksLikeGoogleMeet("Zoom"))
        // "Meet" alone is not enough without a meeting code.
        XCTAssertFalse(MeetingDetector.looksLikeGoogleMeet("Meet the team — Notion"))
    }
}
