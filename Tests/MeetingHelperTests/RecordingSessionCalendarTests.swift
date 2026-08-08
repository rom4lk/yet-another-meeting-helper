import XCTest
@testable import MeetingHelper

@MainActor
final class RecordingSessionCalendarTests: XCTestCase {

    private func makeSession(title: String = "Meet — abc-defg-hij") -> RecordingSession {
        RecordingSession(
            detected: DetectedMeeting(
                kind: .googleMeet,
                title: title,
                audioPrefixes: [],
                detectedAt: Date()
            ),
            settings: AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            engine: TranscriptionEngine()
        )
    }

    private func match(title: String, isConfident: Bool) -> CalendarEventMatcher.Match {
        CalendarEventMatcher.Match(
            event: CalendarEvent(
                id: "event-1",
                iCalUID: "event-1",
                calendarTitle: "me@work.com",
                title: title,
                start: Date(),
                end: Date().addingTimeInterval(3600),
                organizerEmail: nil,
                attendees: [CalendarAttendee(email: "ivan@example.com")],
                conferenceURLs: []
            ),
            score: isConfident ? 120 : 20,
            isConfident: isConfident
        )
    }

    func testAConfidentMatchRenamesTheRecording() {
        let session = makeSession()

        session.apply(match(title: "Quarterly roadmap review", isConfident: true))

        XCTAssertEqual(session.title, "Quarterly roadmap review")
        XCTAssertEqual(session.calendar?.title, "Quarterly roadmap review")
    }

    func testAnUncertainMatchIsIgnored() {
        let session = makeSession()

        session.apply(match(title: "Dentist", isConfident: false))

        XCTAssertEqual(session.title, "Meet — abc-defg-hij")
        XCTAssertNil(session.calendar)
    }
}
