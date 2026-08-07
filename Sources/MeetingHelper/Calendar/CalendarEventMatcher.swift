import Foundation

/// Decides which calendar event a detected meeting is.
///
/// The signals differ sharply in strength, so they are scored rather than combined into one test.
/// A conference code shared between the window title and the event's join link is proof; a similar
/// title is an argument; overlapping in time is barely more than a coincidence, since a busy
/// calendar has something running at almost any moment.
///
/// Everything here is a pure function of its arguments so the decisions stay testable without a
/// network or a running meeting.
enum CalendarEventMatcher {
    struct Match {
        let event: CalendarEvent
        let score: Int
        /// Whether the winner is clear enough to rename the recording without asking. When it is
        /// not, the interface offers the candidates instead of guessing.
        let isConfident: Bool
    }

    /// How far outside an event a meeting can start and still belong to it. People join early and
    /// calls run over.
    static let tolerance: TimeInterval = 10 * 60

    private static let conferenceCodeScore = 100
    private static let titleScore = 60
    private static let insideIntervalScore = 20
    /// A single candidate that is actually running is usually right, but not by enough of a margin
    /// to rename a recording behind the user's back.
    private static let confidentScore = 60

    /// Ranks the events that could be this meeting, best first.
    static func candidates(for meeting: DetectedMeeting, in events: [CalendarEvent]) -> [Match] {
        let deduplicated = deduplicate(events)
        let scored = deduplicated.compactMap { event -> Match? in
            guard isWithinTolerance(meeting.detectedAt, of: event) else { return nil }
            let score = score(meeting: meeting, event: event)
            return Match(event: event, score: score, isConfident: score >= confidentScore)
        }

        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            // Same score: prefer the event that started closer to the moment of detection.
            let lhsDistance = abs(lhs.event.start.timeIntervalSince(meeting.detectedAt))
            let rhsDistance = abs(rhs.event.start.timeIntervalSince(meeting.detectedAt))
            return lhsDistance < rhsDistance
        }
    }

    /// The single best event, or `nil` when nothing is close enough to be worth showing.
    static func bestMatch(for meeting: DetectedMeeting, in events: [CalendarEvent]) -> Match? {
        let ranked = candidates(for: meeting, in: events)
        guard let best = ranked.first else { return nil }

        // A tie between two events is not a match. Renaming the recording after the wrong one is
        // worse than leaving the window title in place.
        if ranked.count > 1, ranked[1].score == best.score {
            return Match(event: best.event, score: best.score, isConfident: false)
        }
        return best
    }

    // MARK: - Scoring

    private static func isWithinTolerance(_ moment: Date, of event: CalendarEvent) -> Bool {
        moment >= event.start.addingTimeInterval(-tolerance)
            && moment <= event.end.addingTimeInterval(tolerance)
    }

    private static func score(meeting: DetectedMeeting, event: CalendarEvent) -> Int {
        var score = 0

        if sharesConferenceCode(meeting: meeting, event: event) {
            score += conferenceCodeScore
        }
        score += Int(Double(titleScore) * titleSimilarity(meeting.title, event.title))
        if meeting.detectedAt >= event.start, meeting.detectedAt <= event.end {
            score += insideIntervalScore
        }

        return score
    }

    /// A Google Meet window title carries the meeting code (`Meet — abc-defg-hij`), and the event
    /// carries the same code inside its join link. When both are present it is the one signal that
    /// cannot be a coincidence.
    ///
    /// Zoom has no equivalent: its window shows the topic, not the numeric meeting id, so a Zoom
    /// call is matched on its title and time instead.
    static func sharesConferenceCode(meeting: DetectedMeeting, event: CalendarEvent) -> Bool {
        let codesInTitle = conferenceCodes(in: meeting.title)
        guard !codesInTitle.isEmpty else { return false }

        let codesInEvent = Set(event.conferenceURLs.flatMap { conferenceCodes(in: $0.absoluteString) })
        return !codesInTitle.isDisjoint(with: codesInEvent)
    }

    /// Meet codes look like `abc-defg-hij`. The pattern is specific enough that an ordinary phrase
    /// does not produce one.
    static func conferenceCodes(in text: String) -> Set<String> {
        let pattern = "[a-z]{3}-[a-z]{4}-[a-z]{3}"
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let matches = regex.matches(in: text, range: range).compactMap { match -> String? in
            guard let range = Range(match.range, in: text) else { return nil }
            return text[range].lowercased()
        }
        return Set(matches)
    }

    /// Overlap of the significant words in the two titles, from 0 to 1.
    ///
    /// A browser meeting's title is the tab title and a Zoom one is the meeting topic; both are
    /// usually the event's own name, but neither is guaranteed to be it exactly. Word overlap
    /// survives a suffix, a prefix or a reordering, which an equality test does not.
    static func titleSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsWords = significantWords(in: lhs)
        let rhsWords = significantWords(in: rhs)
        guard !lhsWords.isEmpty, !rhsWords.isEmpty else { return 0 }

        let shared = lhsWords.intersection(rhsWords).count
        return Double(shared) / Double(min(lhsWords.count, rhsWords.count))
    }

    /// Words worth comparing: single characters and digits carry no meaning here, and the words
    /// that every second meeting is called would match everything.
    private static func significantWords(in title: String) -> Set<String> {
        let separators = CharacterSet.alphanumerics.inverted
        let words = title.lowercased()
            .components(separatedBy: separators)
            .filter { $0.count > 1 && !stopWords.contains($0) }

        return Set(words)
    }

    private static let stopWords: Set<String> = [
        "meet", "meeting", "call", "sync", "the", "and", "with", "zoom", "google"
    ]

    // MARK: - Deduplication

    /// The same event invited to both a work and a personal account arrives twice. Keep one copy,
    /// preferring the account where the user accepted it — that is the one whose roster reflects
    /// the meeting they are actually in.
    static func deduplicate(_ events: [CalendarEvent]) -> [CalendarEvent] {
        var best: [String: CalendarEvent] = [:]

        for event in events {
            guard let existing = best[event.occurrenceKey] else {
                best[event.occurrenceKey] = event
                continue
            }
            if rank(event) > rank(existing) {
                best[event.occurrenceKey] = event
            }
        }

        return best.values.sorted { $0.start < $1.start }
    }

    private static func rank(_ event: CalendarEvent) -> Int {
        guard let response = event.attendees.first(where: \.isSelf)?.responseStatus else { return 0 }
        switch response {
        case .accepted: return 3
        case .tentative: return 2
        case .needsAction: return 1
        case .declined: return 0
        }
    }
}
