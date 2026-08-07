import SwiftUI

/// The roster of a matched calendar event, compact enough for a header that is already crowded.
///
/// The first two names are shown and the rest are counted; a click opens the full list with each
/// person's answer to the invitation.
struct CalendarParticipantsLabel: View {
    let info: MeetingCalendarInfo

    @State private var isShowingList = false

    var body: some View {
        Button {
            isShowingList.toggle()
        } label: {
            Label(summary, systemImage: "person.2")
        }
        .buttonStyle(.plain)
        .disabled(info.attendees.isEmpty)
        .popover(isPresented: $isShowingList, arrowEdge: .bottom) {
            list
        }
    }

    private var summary: String {
        let others = info.otherAttendees
        guard !others.isEmpty else { return info.calendarTitle }

        let shown = others.prefix(2).map(\.name).joined(separator: ", ")
        let remaining = others.count - min(others.count, 2)
        guard remaining > 0 else { return shown }

        return "\(shown) +\(remaining)"
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(info.title)
                .font(.headline)
            Text(info.calendarTitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            ForEach(info.attendees) { attendee in
                HStack(spacing: 8) {
                    Image(systemName: icon(for: attendee.responseStatus))
                        .foregroundStyle(color(for: attendee.responseStatus))
                        .frame(width: 14)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(attendee.name + (attendee.isSelf ? " (you)" : ""))
                        if attendee.name != attendee.email {
                            Text(attendee.email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(minWidth: 240, maxWidth: 360, alignment: .leading)
    }

    private func icon(for status: CalendarAttendee.ResponseStatus) -> String {
        switch status {
        case .accepted: return "checkmark.circle.fill"
        case .declined: return "xmark.circle.fill"
        case .tentative: return "questionmark.circle.fill"
        case .needsAction: return "circle"
        }
    }

    private func color(for status: CalendarAttendee.ResponseStatus) -> Color {
        switch status {
        case .accepted: return .green
        case .declined: return .red
        case .tentative: return .orange
        case .needsAction: return .secondary
        }
    }
}
