import Foundation

struct Meeting: Identifiable, Codable, Hashable {
    static let deletionConfirmationThreshold: TimeInterval = 5 * 60

    let id: UUID
    var title: String
    var kind: DetectedMeeting.Kind
    var startedAt: Date
    var duration: TimeInterval
    var hasMicTrack: Bool
    var hasSystemTrack: Bool

    init(
        id: UUID = UUID(),
        title: String,
        kind: DetectedMeeting.Kind,
        startedAt: Date = Date(),
        duration: TimeInterval = 0,
        hasMicTrack: Bool = false,
        hasSystemTrack: Bool = false
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.startedAt = startedAt
        self.duration = duration
        self.hasMicTrack = hasMicTrack
        self.hasSystemTrack = hasSystemTrack
    }

    var formattedDuration: String { duration.clockString }

    var requiresDeletionConfirmation: Bool {
        duration > Self.deletionConfirmationThreshold
    }

    func shouldBeSaved(minimumDuration: TimeInterval) -> Bool {
        duration >= minimumDuration
    }
}

/// On-disk layout. One directory per meeting keeps everything inspectable with Finder and
/// makes a partially written recording survivable — a crash costs at most the last buffer.
/// The library root is a parameter with a default rather than a constant so that tests can run
/// against a temporary directory instead of the user's real recordings.
enum MeetingLibrary {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingHelper", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func directory(for id: UUID, in root: URL = root) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    @discardableResult
    static func createDirectory(for id: UUID, in root: URL = root) throws -> URL {
        let url = directory(for: id, in: root)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func metadataURL(for id: UUID, in root: URL = root) -> URL {
        directory(for: id, in: root).appendingPathComponent("meeting.json")
    }

    static func transcriptURL(for id: UUID, in root: URL = root) -> URL {
        directory(for: id, in: root).appendingPathComponent("transcript.json")
    }

    static func micTrackURL(for id: UUID, in root: URL = root) -> URL {
        directory(for: id, in: root).appendingPathComponent("mic.wav")
    }

    static func systemTrackURL(for id: UUID, in root: URL = root) -> URL {
        directory(for: id, in: root).appendingPathComponent("system.wav")
    }

    static func mixdownURL(for id: UUID, in root: URL = root) -> URL {
        directory(for: id, in: root).appendingPathComponent("mix.m4a")
    }
}
