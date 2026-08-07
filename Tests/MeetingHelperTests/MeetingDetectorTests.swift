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

    // MARK: - Ktalk recognition

    /// The web client leaves a page title empty on the conference route, and its own name is then
    /// the whole document title.
    func testRecognizesTitlesThatAreTheAppNameAlone() {
        XCTAssertTrue(MeetingDetector.looksLikeKtalk("Толк"))
        XCTAssertTrue(MeetingDetector.looksLikeKtalk("Толк - Google Chrome"))
        XCTAssertTrue(MeetingDetector.looksLikeKtalk("Толк — Arc"))
    }

    func testRecognizesTitlesEndingWithTheAppName() {
        XCTAssertTrue(MeetingDetector.looksLikeKtalk("Weekly sync — Толк"))
        XCTAssertTrue(MeetingDetector.looksLikeKtalk("Weekly sync — Толк - Google Chrome"))
    }

    /// The app name occurs inside ordinary Russian words, and a tab holding one must not claim a
    /// browser that is in a meeting elsewhere.
    func testRejectsTitlesMerelyContainingTheAppName() {
        XCTAssertFalse(MeetingDetector.looksLikeKtalk("Толкование снов — Wikipedia"))
        XCTAssertFalse(MeetingDetector.looksLikeKtalk("Толк для начинающих"))
        XCTAssertFalse(MeetingDetector.looksLikeKtalk("Inbox — Gmail"))
    }

    // MARK: - PWA hosts

    func testMatchesPWAHostAndItsSubdomains() {
        let ktalk = BrowserMeetingService.all.first { $0.kind == .ktalk }!
        XCTAssertTrue(ktalk.matches(pwaHost: "ktalk.ru"))
        XCTAssertTrue(ktalk.matches(pwaHost: "tbank.ktalk.ru"))
        XCTAssertFalse(ktalk.matches(pwaHost: "notktalk.ru"))
        XCTAssertFalse(ktalk.matches(pwaHost: "ktalk.ru.example.com"))

        let meet = BrowserMeetingService.all.first { $0.kind == .googleMeet }!
        XCTAssertTrue(meet.matches(pwaHost: "meet.google.com"))
        XCTAssertFalse(meet.matches(pwaHost: "mail.google.com"))
    }
}
