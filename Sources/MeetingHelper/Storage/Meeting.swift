import Foundation

struct Meeting: Identifiable, Codable, Hashable {
    static let deletionConfirmationThreshold: TimeInterval = 5 * 60

    let id: UUID
    var title: String
    var kind: DetectedMeeting.Kind
    var startedAt: Date
    var endedAt: Date?
    var duration: TimeInterval
    var hasMicTrack: Bool
    var hasSystemTrack: Bool

    init(
        id: UUID = UUID(),
        title: String,
        kind: DetectedMeeting.Kind,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        duration: TimeInterval = 0,
        hasMicTrack: Bool = false,
        hasSystemTrack: Bool = false
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.duration = duration
        self.hasMicTrack = hasMicTrack
        self.hasSystemTrack = hasSystemTrack
    }

    var formattedDuration: String {
        let total = Int(duration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    var requiresDeletionConfirmation: Bool {
        duration > Self.deletionConfirmationThreshold
    }

    func shouldBeSaved(minimumDuration: TimeInterval) -> Bool {
        duration >= minimumDuration
    }
}

/// On-disk layout. One directory per meeting keeps everything inspectable with Finder and
/// makes a partially written recording survivable — a crash costs at most the last buffer.
enum MeetingLibrary {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingHelper", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func createDirectory(for id: UUID) throws -> URL {
        let url = directory(for: id)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func metadataURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("meeting.json") }
    static func transcriptURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("transcript.json") }
    static func micTrackURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("mic.wav") }
    static func systemTrackURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("system.wav") }
    static func mixdownURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("mix.m4a") }
}
