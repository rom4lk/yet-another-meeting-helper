import Foundation

@MainActor
final class MeetingStore: ObservableObject {
    @Published private(set) var meetings: [Meeting] = []

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init() {
        reload()
    }

    func reload() {
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: MeetingLibrary.root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        meetings = directories
            .compactMap { directory -> Meeting? in
                let url = directory.appendingPathComponent("meeting.json")
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Meeting.self, from: data)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func save(_ meeting: Meeting) {
        do {
            _ = try MeetingLibrary.createDirectory(for: meeting.id)
            let data = try encoder.encode(meeting)
            try data.write(to: MeetingLibrary.metadataURL(for: meeting.id), options: .atomic)
        } catch {
            Log.store.error("Cannot save meeting: \(error, privacy: .public)")
        }

        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.insert(meeting, at: 0)
            meetings.sort { $0.startedAt > $1.startedAt }
        }
    }

    func delete(_ meeting: Meeting) {
        try? FileManager.default.removeItem(at: MeetingLibrary.directory(for: meeting.id))
        meetings.removeAll { $0.id == meeting.id }
    }

    func saveTranscript(_ lines: [TranscriptLine], for id: UUID) {
        do {
            _ = try MeetingLibrary.createDirectory(for: id)
            let data = try encoder.encode(lines)
            try data.write(to: MeetingLibrary.transcriptURL(for: id), options: .atomic)
        } catch {
            Log.store.error("Cannot save transcript: \(error, privacy: .public)")
        }
    }

    func transcript(for id: UUID) -> [TranscriptLine] {
        guard let data = try? Data(contentsOf: MeetingLibrary.transcriptURL(for: id)),
              let lines = try? decoder.decode([TranscriptLine].self, from: data)
        else { return [] }
        return lines
    }
}
