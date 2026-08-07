import XCTest
@testable import MeetingHelper

@MainActor
final class MeetingStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testSavedMeetingSurvivesAReload() {
        let store = MeetingStore(root: root)
        let meeting = Meeting(title: "Weekly sync", kind: .zoom, duration: 42)

        store.save(meeting)

        let reopened = MeetingStore(root: root)
        XCTAssertEqual(reopened.meetings.map(\.id), [meeting.id])
        XCTAssertEqual(reopened.meetings.first?.title, "Weekly sync")
        XCTAssertEqual(reopened.meetings.first?.duration, 42)
    }

    func testSavingAnExistingMeetingUpdatesItInPlace() {
        let store = MeetingStore(root: root)
        var meeting = Meeting(title: "Untitled", kind: .manual)
        store.save(meeting)

        meeting.title = "Renamed"
        store.save(meeting)

        XCTAssertEqual(store.meetings.count, 1)
        XCTAssertEqual(MeetingStore(root: root).meetings.first?.title, "Renamed")
    }

    func testMeetingsAreSortedNewestFirst() {
        let store = MeetingStore(root: root)
        let older = Meeting(title: "Older", kind: .manual, startedAt: Date(timeIntervalSince1970: 1_000))
        let newer = Meeting(title: "Newer", kind: .manual, startedAt: Date(timeIntervalSince1970: 2_000))

        store.save(older)
        store.save(newer)

        XCTAssertEqual(store.meetings.map(\.title), ["Newer", "Older"])
        XCTAssertEqual(MeetingStore(root: root).meetings.map(\.title), ["Newer", "Older"])
    }

    func testDeletingRemovesTheWholeMeetingDirectory() {
        let store = MeetingStore(root: root)
        let meeting = Meeting(title: "Doomed", kind: .manual)
        store.save(meeting)
        store.saveTranscript([TranscriptLine(source: .me, offset: 0, text: "Hello")], for: meeting.id)
        let directory = MeetingLibrary.directory(for: meeting.id, in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))

        store.delete(meeting)

        XCTAssertTrue(store.meetings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(MeetingStore(root: root).meetings.isEmpty)
    }

    func testTranscriptRoundTrips() {
        let store = MeetingStore(root: root)
        let meeting = Meeting(title: "With transcript", kind: .googleMeet)
        store.save(meeting)
        let lines = [
            TranscriptLine(source: .me, offset: 1.5, text: "Can you hear me?"),
            TranscriptLine(source: .others, offset: 3, text: "Loud and clear.")
        ]

        store.saveTranscript(lines, for: meeting.id)

        XCTAssertEqual(MeetingStore(root: root).transcript(for: meeting.id), lines)
    }

    func testTranscriptIsEmptyWhenNoneWasSaved() {
        let store = MeetingStore(root: root)

        XCTAssertTrue(store.transcript(for: UUID()).isEmpty)
    }

    /// Meetings written before `endedAt` was dropped from the model must still load.
    func testMetadataWithUnknownFieldsStillDecodes() throws {
        let id = UUID()
        try MeetingLibrary.createDirectory(for: id, in: root)
        let json = """
        {
          "id": "\(id.uuidString)",
          "title": "Legacy meeting",
          "kind": "zoom",
          "startedAt": "2026-08-01T10:00:00Z",
          "endedAt": "2026-08-01T10:30:00Z",
          "duration": 1800,
          "hasMicTrack": true,
          "hasSystemTrack": false
        }
        """
        try Data(json.utf8).write(to: MeetingLibrary.metadataURL(for: id, in: root))

        let store = MeetingStore(root: root)

        XCTAssertEqual(store.meetings.map(\.title), ["Legacy meeting"])
        XCTAssertEqual(store.meetings.first?.duration, 1800)
    }

    func testMetadataWithUnknownMeetingKindStillDecodes() throws {
        let id = UUID()
        try MeetingLibrary.createDirectory(for: id, in: root)
        let json = """
        {
          "id": "\(id.uuidString)",
          "title": "Future meeting provider",
          "kind": "futureProvider",
          "startedAt": "2026-08-03T08:00:26Z",
          "duration": 2803,
          "hasMicTrack": true,
          "hasSystemTrack": true
        }
        """
        try Data(json.utf8).write(to: MeetingLibrary.metadataURL(for: id, in: root))

        let store = MeetingStore(root: root)

        XCTAssertEqual(store.meetings.first?.kind, .unknown("futureProvider"))
        XCTAssertEqual(store.meetings.first?.kind.rawValue, "futureProvider")
        XCTAssertEqual(store.meetings.first?.kind.displayName, "Other")
    }
}
