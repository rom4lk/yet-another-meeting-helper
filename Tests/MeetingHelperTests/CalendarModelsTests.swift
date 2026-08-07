import XCTest
@testable import MeetingHelper

final class CalendarModelsTests: XCTestCase {

    // MARK: - Attendee names

    func testUsesTheDisplayNameWhenTheCalendarKnowsOne() {
        let attendee = CalendarAttendee(email: "ivan.petrov@example.com", displayName: "Ivan Petrov")

        XCTAssertEqual(attendee.name, "Ivan Petrov")
    }

    func testBuildsANameFromTheAddressWhenTheCalendarKnowsNone() {
        XCTAssertEqual(CalendarAttendee(email: "ivan.petrov@example.com").name, "Ivan Petrov")
        XCTAssertEqual(CalendarAttendee(email: "ivan_petrov@example.com").name, "Ivan Petrov")
        XCTAssertEqual(CalendarAttendee(email: "ivan-petrov@example.com").name, "Ivan Petrov")
        XCTAssertEqual(CalendarAttendee(email: "ivan.petrov+cal@example.com").name, "Ivan Petrov")
        XCTAssertEqual(CalendarAttendee(email: "ivanpetrov@example.com").name, "Ivanpetrov")
    }

    func testAnEmptyDisplayNameFallsBackToTheAddress() {
        XCTAssertEqual(CalendarAttendee(email: "ivan.petrov@example.com", displayName: "  ").name, "Ivan Petrov")
    }

    func testAnAddressWithoutALocalPartIsLeftAlone() {
        XCTAssertEqual(CalendarAttendee(email: "room-42@resource.calendar.google.com").name, "Room 42")
        XCTAssertEqual(CalendarAttendee(email: "").name, "")
    }

    // MARK: - Meeting metadata

    func testMeetingCalendarInfoKeepsEverybodyButExposesTheOthersSeparately() {
        let event = CalendarEvent(
            id: "abc",
            iCalUID: "abc@google.com",
            calendarTitle: "me@work.com",
            title: "Roadmap review",
            start: Date(),
            end: Date().addingTimeInterval(3600),
            organizerEmail: "lead@example.com",
            attendees: [
                CalendarAttendee(email: "me@example.com", isSelf: true),
                CalendarAttendee(email: "lead@example.com", isOrganizer: true),
                CalendarAttendee(email: "ivan@example.com")
            ],
            conferenceURLs: []
        )

        let info = MeetingCalendarInfo(event: event)

        XCTAssertEqual(info.attendees.count, 3)
        XCTAssertEqual(info.otherAttendees.map(\.email), ["lead@example.com", "ivan@example.com"])
        XCTAssertEqual(info.calendarTitle, "me@work.com")
        XCTAssertEqual(info.title, "Roadmap review")
    }

    // MARK: - Stored meetings

    func testAMeetingRecordedBeforeCalendarSupportStillDecodes() throws {
        let json = """
            {
              "id": "8B9C7A5E-6E9E-4E51-9E0B-2B0A1F2C3D4E",
              "title": "Weekly sync",
              "kind": "zoom",
              "startedAt": "2026-08-07T10:00:00Z",
              "duration": 1800,
              "hasMicTrack": true,
              "hasSystemTrack": true
            }
            """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meeting = try decoder.decode(Meeting.self, from: Data(json.utf8))

        XCTAssertNil(meeting.calendar)
        XCTAssertEqual(meeting.title, "Weekly sync")
    }

    func testCalendarInfoSurvivesAStorageRoundTrip() throws {
        let event = CalendarEvent(
            id: "abc",
            iCalUID: "abc@google.com",
            calendarTitle: "me@work.com",
            title: "Roadmap review",
            start: Date(),
            end: Date().addingTimeInterval(3600),
            organizerEmail: "lead@example.com",
            attendees: [CalendarAttendee(email: "ivan@example.com", displayName: "Ivan Petrov")],
            conferenceURLs: []
        )
        let meeting = Meeting(
            title: "Roadmap review",
            kind: .googleMeet,
            calendar: MeetingCalendarInfo(event: event)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(Meeting.self, from: encoder.encode(meeting))

        XCTAssertEqual(restored.calendar?.attendees.first?.displayName, "Ivan Petrov")
        XCTAssertEqual(restored.calendar?.calendarTitle, "me@work.com")
    }
}
