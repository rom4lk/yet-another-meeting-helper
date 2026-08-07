import XCTest
@testable import MeetingHelper

final class CalendarEventMatcherTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Helpers

    private func event(
        id: String = "event-1",
        iCalUID: String? = nil,
        title: String,
        startsIn minutes: Double = 0,
        lasts duration: Double = 60,
        conferenceURLs: [String] = [],
        attendees: [CalendarAttendee] = [],
        calendarTitle: String = "me@work.com"
    ) -> CalendarEvent {
        CalendarEvent(
            id: id,
            iCalUID: iCalUID ?? id,
            calendarTitle: calendarTitle,
            title: title,
            start: now.addingTimeInterval(minutes * 60),
            end: now.addingTimeInterval((minutes + duration) * 60),
            organizerEmail: nil,
            attendees: attendees,
            conferenceURLs: conferenceURLs.compactMap(URL.init(string:))
        )
    }

    private func meeting(
        _ title: String,
        kind: DetectedMeeting.Kind = .googleMeet,
        detectedIn minutes: Double = 0
    ) -> DetectedMeeting {
        DetectedMeeting(
            kind: kind,
            title: title,
            audioPrefixes: [],
            detectedAt: now.addingTimeInterval(minutes * 60)
        )
    }

    // MARK: - Conference code

    func testMeetCodeInWindowTitleMatchesTheEventJoinLink() {
        let right = event(
            id: "right",
            title: "Something else entirely",
            conferenceURLs: ["https://meet.google.com/abc-defg-hij"]
        )
        let wrong = event(
            id: "wrong",
            title: "Something else entirely",
            conferenceURLs: ["https://meet.google.com/zzz-zzzz-zzz"]
        )

        let match = CalendarEventMatcher.bestMatch(for: meeting("Meet — abc-defg-hij"), in: [wrong, right])

        XCTAssertEqual(match?.event.id, "right")
        XCTAssertEqual(match?.isConfident, true)
    }

    func testConferenceCodeMatchIsCaseInsensitive() {
        let event = event(
            title: "Weekly review",
            conferenceURLs: ["https://meet.google.com/ABC-DEFG-HIJ"]
        )

        XCTAssertTrue(
            CalendarEventMatcher.sharesConferenceCode(
                meeting: meeting("Meet — abc-defg-hij"),
                event: event
            )
        )
    }

    func testTitleWithoutACodeSharesNoCode() {
        let event = event(title: "Weekly review", conferenceURLs: ["https://meet.google.com/abc-defg-hij"])

        XCTAssertFalse(
            CalendarEventMatcher.sharesConferenceCode(meeting: meeting("Weekly review"), event: event)
        )
    }

    // MARK: - Title similarity

    func testTitleAloneIsEnoughForAConfidentMatch() {
        let match = CalendarEventMatcher.bestMatch(
            for: meeting("Quarterly roadmap review", kind: .zoom),
            in: [event(title: "Quarterly roadmap review")]
        )

        XCTAssertEqual(match?.isConfident, true)
    }

    func testTitleSimilarityIgnoresWordOrderAndCase() {
        XCTAssertEqual(
            CalendarEventMatcher.titleSimilarity("Roadmap review", "review ROADMAP"),
            1,
            accuracy: 0.001
        )
    }

    func testCommonMeetingWordsDoNotCreateSimilarity() {
        XCTAssertEqual(CalendarEventMatcher.titleSimilarity("Weekly sync", "Zoom Meeting"), 0)
    }

    // MARK: - Time window

    func testEventOutsideToleranceIsNotACandidate() {
        let stale = event(id: "stale", title: "Roadmap review", startsIn: -120, lasts: 30)

        XCTAssertTrue(CalendarEventMatcher.candidates(for: meeting("Roadmap review"), in: [stale]).isEmpty)
    }

    func testJoiningShortlyBeforeTheEventStillMatches() {
        let upcoming = event(title: "Roadmap review", startsIn: 5)

        let match = CalendarEventMatcher.bestMatch(for: meeting("Roadmap review"), in: [upcoming])

        XCTAssertEqual(match?.event.title, "Roadmap review")
    }

    func testRunningEventScoresAboveAnEqualUpcomingOne() {
        let running = event(id: "running", title: "Roadmap review", startsIn: -5, lasts: 30)
        let upcoming = event(id: "upcoming", title: "Roadmap review", startsIn: 5, lasts: 30)

        let ranked = CalendarEventMatcher.candidates(for: meeting("Roadmap review"), in: [upcoming, running])

        XCTAssertEqual(ranked.first?.event.id, "running")
    }

    // MARK: - Ambiguity

    func testTwoEqallyScoredEventsProduceNoConfidentMatch() {
        let first = event(id: "first", title: "Roadmap review", startsIn: -5)
        let second = event(id: "second", title: "Roadmap review", startsIn: -5)

        let match = CalendarEventMatcher.bestMatch(for: meeting("Roadmap review"), in: [first, second])

        XCTAssertNotNil(match)
        XCTAssertEqual(match?.isConfident, false)
    }

    func testUnrelatedEventRunningAtTheSameTimeIsNotConfident() {
        let unrelated = event(title: "Dentist", startsIn: -5)

        let match = CalendarEventMatcher.bestMatch(for: meeting("Weekly sync"), in: [unrelated])

        XCTAssertEqual(match?.isConfident, false)
    }

    func testNoEventsProduceNoMatch() {
        XCTAssertNil(CalendarEventMatcher.bestMatch(for: meeting("Roadmap review"), in: []))
    }

    // MARK: - Deduplication

    func testSameEventInTwoAccountsKeepsTheAcceptedCopy() {
        let declined = event(
            id: "personal",
            iCalUID: "shared-uid",
            title: "Roadmap review",
            attendees: [CalendarAttendee(email: "me@personal.com", responseStatus: .declined, isSelf: true)],
            calendarTitle: "me@personal.com"
        )
        let accepted = event(
            id: "work",
            iCalUID: "shared-uid",
            title: "Roadmap review",
            attendees: [CalendarAttendee(email: "me@work.com", responseStatus: .accepted, isSelf: true)]
        )

        let deduplicated = CalendarEventMatcher.deduplicate([declined, accepted])

        XCTAssertEqual(deduplicated.count, 1)
        XCTAssertEqual(deduplicated.first?.id, "work")
    }

    func testDifferentEventsAreNotDeduplicated() {
        let first = event(id: "first", title: "Roadmap review")
        let second = event(id: "second", title: "Retrospective", startsIn: 60)

        XCTAssertEqual(CalendarEventMatcher.deduplicate([first, second]).count, 2)
    }

    /// Every occurrence of a recurring series carries the identifier of the series, so two of them
    /// inside one window look like duplicates of each other until the start time is taken into
    /// account.
    func testTwoOccurrencesOfTheSameSeriesAreBothKept() {
        let standup = event(id: "first", iCalUID: "series", title: "Standup", lasts: 15)
        let nextStandup = event(id: "second", iCalUID: "series", title: "Standup", startsIn: 60, lasts: 15)

        XCTAssertEqual(CalendarEventMatcher.deduplicate([standup, nextStandup]).count, 2)
    }
}
