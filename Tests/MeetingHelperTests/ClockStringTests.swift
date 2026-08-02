import XCTest
@testable import MeetingHelper

final class ClockStringTests: XCTestCase {
    func testFormatsUnderAnHourAsMinutesAndSeconds() {
        XCTAssertEqual(TimeInterval(0).clockString, "00:00")
        XCTAssertEqual(TimeInterval(9).clockString, "00:09")
        XCTAssertEqual(TimeInterval(75).clockString, "01:15")
        XCTAssertEqual(TimeInterval(3599).clockString, "59:59")
    }

    func testWidensToHoursPastAnHour() {
        XCTAssertEqual(TimeInterval(3600).clockString, "1:00:00")
        XCTAssertEqual(TimeInterval(5415).clockString, "1:30:15")
    }

    func testTruncatesFractionsTowardsZero() {
        XCTAssertEqual(TimeInterval(9.99).clockString, "00:09")
    }

    /// The transcript used to print raw minutes, so a two-hour meeting read as `90:15`.
    func testTranscriptOffsetsPastAnHourAreUnambiguous() {
        let line = TranscriptLine(source: .me, offset: 5415, text: "Anything")

        XCTAssertEqual(line.timestamp, "1:30:15")
    }
}
