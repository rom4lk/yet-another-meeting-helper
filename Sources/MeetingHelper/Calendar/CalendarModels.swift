import Foundation

/// Somebody invited to a calendar event.
struct CalendarAttendee: Codable, Hashable, Identifiable {
    /// An unrecognised value decodes as `needsAction` rather than failing the whole event: a
    /// meeting saved by a later version of the app must not lose its roster here.
    enum ResponseStatus: String, Codable {
        case needsAction
        case declined
        case tentative
        case accepted

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = ResponseStatus(rawValue: raw) ?? .needsAction
        }
    }

    let email: String
    /// Present only when the calendar knows a display name, which for many invitations it does
    /// not. `name` falls back to the address.
    let displayName: String?
    let responseStatus: ResponseStatus
    let isSelf: Bool
    let isOrganizer: Bool

    init(
        email: String,
        displayName: String? = nil,
        responseStatus: ResponseStatus = .needsAction,
        isSelf: Bool = false,
        isOrganizer: Bool = false
    ) {
        self.email = email
        self.displayName = displayName
        self.responseStatus = responseStatus
        self.isSelf = isSelf
        self.isOrganizer = isOrganizer
    }

    var id: String { email }

    var name: String {
        guard let displayName, !displayName.trimmingCharacters(in: .whitespaces).isEmpty else {
            return Self.name(fromEmail: email)
        }
        return displayName
    }

    /// Turns `ivan.petrov+cal@example.com` into `Ivan Petrov`.
    ///
    /// This is a display fallback, not an identity: two people can share a local part across
    /// domains. Matching always uses the address itself.
    static func name(fromEmail email: String) -> String {
        let localPart = email.split(separator: "@").first.map(String.init) ?? email
        let withoutTag = localPart.split(separator: "+").first.map(String.init) ?? localPart
        let words = withoutTag
            .split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }

        return words.isEmpty ? email : words.joined(separator: " ")
    }
}

/// A single occurrence of a calendar event, as the app uses it. Every value here describes one
/// concrete meeting slot, not a recurring series.
struct CalendarEvent: Identifiable, Hashable {
    let id: String
    /// Shared by every copy of the same event, which is what makes deduplication across two
    /// accounts possible. Recurring occurrences share it too — see `occurrenceKey`.
    let iCalUID: String
    /// The calendar this came from, named as the Calendar app names it. Usually the account
    /// address, which is what tells a work event from a personal one.
    let calendarTitle: String
    let title: String
    let start: Date
    let end: Date
    let organizerEmail: String?
    let attendees: [CalendarAttendee]
    /// Every join link the event carries: its URL, and anything URL-shaped in the location or the
    /// notes.
    let conferenceURLs: [URL]

    /// Identifies one occurrence across accounts. `iCalUID` alone would also collapse two
    /// occurrences of the same recurring series into one, and a window can hold both.
    var occurrenceKey: String {
        "\(iCalUID)@\(start.timeIntervalSinceReferenceDate)"
    }
}

/// What a saved meeting keeps from the calendar event it was matched to.
///
/// This is a snapshot rather than a reference. The event can be edited or deleted afterwards, and
/// the recording must still say who was in the room at the time.
struct MeetingCalendarInfo: Codable, Hashable {
    let eventID: String
    let iCalUID: String
    let calendarTitle: String
    let title: String
    let organizerEmail: String?
    let attendees: [CalendarAttendee]

    init(event: CalendarEvent) {
        self.eventID = event.id
        self.iCalUID = event.iCalUID
        self.calendarTitle = event.calendarTitle
        self.title = event.title
        self.organizerEmail = event.organizerEmail
        self.attendees = event.attendees
    }

    /// Everybody except the account owner, which is who the "Others" audio track carries.
    var otherAttendees: [CalendarAttendee] {
        attendees.filter { !$0.isSelf }
    }
}
