import EventKit
import Foundation

extension CalendarEvent {
    /// Reads one EventKit event, or refuses it.
    ///
    /// All-day entries and cancelled ones are dropped: neither can be the call that is being
    /// recorded, and an all-day entry spans every meeting of the day, so keeping them would put a
    /// birthday reminder in front of the real event.
    init?(_ event: EKEvent) {
        guard !event.isAllDay, event.status != .canceled else { return nil }
        guard let identifier = event.eventIdentifier,
              let start = event.startDate,
              let end = event.endDate
        else { return nil }

        let organizerEmail = event.organizer.flatMap { CalendarAttendee.emailAddress(inParticipantURL: $0.url) }

        self.init(
            id: identifier,
            iCalUID: event.calendarItemExternalIdentifier ?? identifier,
            calendarTitle: event.calendar?.title ?? "",
            title: event.title ?? "",
            start: start,
            end: end,
            organizerEmail: organizerEmail,
            attendees: (event.attendees ?? []).compactMap {
                CalendarAttendee($0, organizerEmail: organizerEmail)
            },
            conferenceURLs: Self.conferenceURLs(
                url: event.url,
                location: event.location,
                notes: event.notes
            )
        )
    }

    /// Every link the event carries that could be a join link.
    ///
    /// Google puts the Meet link in the event's own URL field and repeats it in the description;
    /// other services leave it in the location or write it into the text. All three are collected
    /// and the matcher decides which of them means anything.
    static func conferenceURLs(url: URL?, location: String?, notes: String?) -> [URL] {
        var found = url.map { [$0] } ?? []
        found += [location, notes].compactMap { $0 }.flatMap(detectedURLs(in:))

        // The same link in the URL field and in the description is the normal case, not an error.
        var seen: Set<String> = []
        return found.filter { seen.insert($0.absoluteString).inserted }
    }

    private static func detectedURLs(in text: String) -> [URL] {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, range: range).compactMap(\.url)
    }
}

extension CalendarAttendee {
    /// An attendee without a readable address is skipped: the address is the identity everything
    /// else keys on, and a participant that carries none — a resource with an odd URL — is of no
    /// use for naming a voice later.
    init?(_ participant: EKParticipant, organizerEmail: String?) {
        guard let email = Self.emailAddress(inParticipantURL: participant.url) else { return nil }

        self.init(
            email: email,
            displayName: participant.name,
            responseStatus: ResponseStatus(participant.participantStatus),
            isSelf: participant.isCurrentUser,
            isOrganizer: organizerEmail?.caseInsensitiveCompare(email) == .orderedSame
        )
    }

    /// EventKit identifies a participant by URL, which for a person is `mailto:someone@example.com`.
    static func emailAddress(inParticipantURL url: URL) -> String? {
        guard url.scheme?.lowercased() == "mailto" else { return nil }

        let specifier = String(url.absoluteString.dropFirst("mailto:".count))
        let address = specifier.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        let decoded = (address.removingPercentEncoding ?? address)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return decoded.contains("@") ? decoded : nil
    }
}

extension CalendarAttendee.ResponseStatus {
    /// EventKit has more states than an invitation really has. The ones that say nothing about
    /// whether the person is coming — delegated, in process, unknown — read as no answer yet.
    init(_ status: EKParticipantStatus) {
        switch status {
        case .accepted: self = .accepted
        case .declined: self = .declined
        case .tentative: self = .tentative
        default: self = .needsAction
        }
    }
}
