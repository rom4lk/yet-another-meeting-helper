import XCTest
@testable import MeetingsHelper

final class MeetingDeletionTests: XCTestCase {
    func testMeetingAtFiveMinutesDoesNotRequireConfirmation() {
        let meeting = Meeting(title: "Boundary meeting", kind: .manual, duration: 5 * 60)

        XCTAssertFalse(meeting.requiresDeletionConfirmation)
    }

    func testMeetingLongerThanFiveMinutesRequiresConfirmation() {
        let meeting = Meeting(title: "Long meeting", kind: .manual, duration: 5 * 60 + 0.001)

        XCTAssertTrue(meeting.requiresDeletionConfirmation)
    }
}
