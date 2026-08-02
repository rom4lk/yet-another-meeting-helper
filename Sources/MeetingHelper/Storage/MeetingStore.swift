import Foundation

@MainActor
final class MeetingStore: ObservableObject {
    enum LibraryChange {
        case updated
        case deleted(UUID)
    }

    @Published private(set) var meetings: [Meeting] = []

    var onLibraryChange: ((LibraryChange) -> Void)?

    /// Injectable so tests run against a temporary directory instead of the real library.
    private let root: URL

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

    init(root: URL = MeetingLibrary.root) {
        self.root = root
        reload()
    }

    func reload() {
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: root,
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
            try MeetingLibrary.createDirectory(for: meeting.id, in: root)
            let data = try encoder.encode(meeting)
            try data.write(to: MeetingLibrary.metadataURL(for: meeting.id, in: root), options: .atomic)
        } catch {
            Log.store.error("Cannot save meeting: \(error, privacy: .public)")
        }

        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.insert(meeting, at: 0)
            meetings.sort { $0.startedAt > $1.startedAt }
        }
        onLibraryChange?(.updated)
    }

    func delete(_ meeting: Meeting) {
        let wasSaved = meetings.contains { $0.id == meeting.id }
        try? FileManager.default.removeItem(at: MeetingLibrary.directory(for: meeting.id, in: root))
        meetings.removeAll { $0.id == meeting.id }
        if wasSaved {
            onLibraryChange?(.deleted(meeting.id))
        }
    }

    func saveTranscript(_ lines: [TranscriptLine], for id: UUID) {
        do {
            try MeetingLibrary.createDirectory(for: id, in: root)
            let data = try encoder.encode(lines)
            try data.write(to: MeetingLibrary.transcriptURL(for: id, in: root), options: .atomic)
        } catch {
            Log.store.error("Cannot save transcript: \(error, privacy: .public)")
        }
        if meetings.contains(where: { $0.id == id }) {
            onLibraryChange?(.updated)
        }
    }

    func transcript(for id: UUID) -> [TranscriptLine] {
        guard let data = try? Data(contentsOf: MeetingLibrary.transcriptURL(for: id, in: root)),
              let lines = try? decoder.decode([TranscriptLine].self, from: data)
        else { return [] }
        return lines
    }
}
