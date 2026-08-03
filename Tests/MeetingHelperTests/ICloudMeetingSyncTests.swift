import Foundation
import XCTest
@testable import MeetingHelper

final class ICloudMeetingSyncTests: XCTestCase {
    private var temporaryRoot: URL!
    private var localMeetingsRoot: URL!
    private var localTombstonesRoot: URL!
    private var containerRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ICloudMeetingSyncTests-\(UUID().uuidString)", isDirectory: true)
        localMeetingsRoot = temporaryRoot.appendingPathComponent("LocalMeetings", isDirectory: true)
        localTombstonesRoot = temporaryRoot.appendingPathComponent("LocalTombstones", isDirectory: true)
        containerRoot = temporaryRoot.appendingPathComponent("iCloudContainer", isDirectory: true)
        try FileManager.default.createDirectory(at: localMeetingsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    func testTenMeetingLimitUploadsOnlyTheNewestMeetings() async throws {
        let meetings = try (0..<12).map { offset in
            try writeMeeting(
                title: "Meeting \(offset)",
                startedAt: Date(timeIntervalSince1970: TimeInterval(offset)),
                to: localMeetingsRoot
            )
        }
        let engine = makeEngine()

        let result = try await engine.synchronize(limit: .ten, folderURL: containerRoot)

        XCTAssertEqual(result, .synchronized(localLibraryChanged: false))
        let remoteIDs = try meetingIDs(in: remoteMeetingsRoot)
        XCTAssertEqual(remoteIDs.count, 10)
        XCTAssertFalse(remoteIDs.contains(meetings[0].id))
        XCTAssertFalse(remoteIDs.contains(meetings[1].id))
        XCTAssertEqual(try meetingIDs(in: localMeetingsRoot).count, 12)
    }

    func testRemoteMeetingIsDownloadedLocally() async throws {
        let remote = try writeMeeting(
            title: "Remote meeting",
            startedAt: Date(),
            to: remoteMeetingsRoot
        )
        let engine = makeEngine()

        let result = try await engine.synchronize(limit: .thirty, folderURL: containerRoot)

        XCTAssertEqual(result, .synchronized(localLibraryChanged: true))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: localMeetingsRoot.appendingPathComponent(remote.id.uuidString).path
        ))
    }

    func testNewerRemoteMeetingReplacesLocalCopy() async throws {
        let meetingID = UUID()
        let local = try writeMeeting(
            id: meetingID,
            title: "Local title",
            startedAt: Date(),
            to: localMeetingsRoot
        )
        let remote = try writeMeeting(
            id: meetingID,
            title: "Remote title",
            startedAt: local.startedAt,
            to: remoteMeetingsRoot
        )
        let remoteMetadataURL = remoteMeetingsRoot
            .appendingPathComponent(remote.id.uuidString)
            .appendingPathComponent("meeting.json")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)],
            ofItemAtPath: remoteMetadataURL.path
        )
        let engine = makeEngine()

        let result = try await engine.synchronize(limit: .unlimited, folderURL: containerRoot)

        XCTAssertEqual(result, .synchronized(localLibraryChanged: true))
        XCTAssertEqual(try readMeeting(id: meetingID, from: localMeetingsRoot).title, "Remote title")
    }

    func testDeletionTombstoneRemovesLocalAndRemoteCopies() async throws {
        let meeting = try writeMeeting(title: "Delete me", startedAt: Date(), to: localMeetingsRoot)
        _ = try writeMeeting(
            id: meeting.id,
            title: meeting.title,
            startedAt: meeting.startedAt,
            to: remoteMeetingsRoot
        )
        let engine = makeEngine()

        try await engine.recordDeletion(of: meeting.id)
        let result = try await engine.synchronize(limit: .fifty, folderURL: containerRoot)

        XCTAssertEqual(result, .synchronized(localLibraryChanged: true))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: localMeetingsRoot.appendingPathComponent(meeting.id.uuidString).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: remoteMeetingsRoot.appendingPathComponent(meeting.id.uuidString).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: remoteTombstonesRoot
                .appendingPathComponent(meeting.id.uuidString)
                .appendingPathExtension("deleted")
                .path
        ))
    }

    func testRemoteDeletionTombstoneRemovesLocalCopy() async throws {
        let meeting = try writeMeeting(
            title: "Deleted elsewhere",
            startedAt: Date(),
            to: localMeetingsRoot
        )
        try FileManager.default.createDirectory(
            at: remoteTombstonesRoot,
            withIntermediateDirectories: true
        )
        try Data().write(to: remoteTombstonesRoot
            .appendingPathComponent(meeting.id.uuidString)
            .appendingPathExtension("deleted"))
        let engine = makeEngine()

        let result = try await engine.synchronize(limit: .ten, folderURL: containerRoot)

        XCTAssertEqual(result, .synchronized(localLibraryChanged: true))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: localMeetingsRoot.appendingPathComponent(meeting.id.uuidString).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: localTombstonesRoot
                .appendingPathComponent(meeting.id.uuidString)
                .appendingPathExtension("deleted")
                .path
        ))
    }

    /// Recognition can be re-run over an existing meeting, which rewrites the transcript and
    /// nothing else. Comparing only `meeting.json` would leave the two copies equal forever.
    func testTranscriptChangeReachesTheOtherSideWithoutAMetadataRewrite() async throws {
        let meetingID = UUID()
        let meeting = try writeMeeting(
            id: meetingID,
            title: "Unchanged",
            startedAt: Date(),
            to: localMeetingsRoot
        )
        try writeMeeting(
            id: meetingID,
            title: "Unchanged",
            startedAt: meeting.startedAt,
            to: remoteMeetingsRoot
        )

        let shared = Date(timeIntervalSince1970: 1_000)
        for root in [localMeetingsRoot!, remoteMeetingsRoot] {
            let directory = root.appendingPathComponent(meetingID.uuidString)
            for name in ["meeting.json", "mix.m4a"] {
                try setModificationDate(shared, of: directory.appendingPathComponent(name))
            }
        }
        let transcript = localMeetingsRoot
            .appendingPathComponent(meetingID.uuidString)
            .appendingPathComponent("transcript.json")
        try Data("[]".utf8).write(to: transcript)
        try setModificationDate(shared.addingTimeInterval(10), of: transcript)

        let result = try await makeEngine().synchronize(limit: .unlimited, folderURL: containerRoot)

        XCTAssertEqual(result, .synchronized(localLibraryChanged: false))
        XCTAssertEqual(
            try Data(contentsOf: remoteMeetingsRoot
                .appendingPathComponent(meetingID.uuidString)
                .appendingPathComponent("transcript.json")),
            Data("[]".utf8)
        )
    }

    func testEditedTitleDoesNotCopyTheRecordingAgain() async throws {
        var meeting = try writeMeeting(title: "Before", startedAt: Date(), to: localMeetingsRoot)
        let engine = makeEngine()
        _ = try await engine.synchronize(limit: .unlimited, folderURL: containerRoot)

        let remoteDirectory = remoteMeetingsRoot.appendingPathComponent(meeting.id.uuidString)
        let audio = try fileIdentity(of: remoteDirectory.appendingPathComponent("mix.m4a"))
        let metadata = try fileIdentity(of: remoteDirectory.appendingPathComponent("meeting.json"))

        meeting.title = "After"
        try writeMetadata(meeting, to: localMeetingsRoot, modifiedAt: Date().addingTimeInterval(10))

        _ = try await engine.synchronize(limit: .unlimited, folderURL: containerRoot)

        XCTAssertEqual(try readMeeting(id: meeting.id, from: remoteMeetingsRoot).title, "After")
        XCTAssertEqual(
            try fileIdentity(of: remoteDirectory.appendingPathComponent("mix.m4a")),
            audio,
            "The recording was copied again although only the title changed"
        )
        XCTAssertNotEqual(
            try fileIdentity(of: remoteDirectory.appendingPathComponent("meeting.json")),
            metadata
        )
    }

    func testFileRemovedFromTheSourceDisappearsFromTheMirror() async throws {
        let meeting = try writeMeeting(title: "Trimmed", startedAt: Date(), to: localMeetingsRoot)
        let engine = makeEngine()
        _ = try await engine.synchronize(limit: .unlimited, folderURL: containerRoot)

        try FileManager.default.removeItem(at: localMeetingsRoot
            .appendingPathComponent(meeting.id.uuidString)
            .appendingPathComponent("mix.m4a"))
        try writeMetadata(meeting, to: localMeetingsRoot, modifiedAt: Date().addingTimeInterval(10))

        _ = try await engine.synchronize(limit: .unlimited, folderURL: containerRoot)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: remoteMeetingsRoot
                .appendingPathComponent(meeting.id.uuidString)
                .appendingPathComponent("mix.m4a")
                .path
        ))
    }

    func testMissingSyncFolderIsUnavailable() async throws {
        try FileManager.default.removeItem(at: containerRoot)
        let engine = makeEngine()

        let result = try await engine.synchronize(limit: .ten, folderURL: containerRoot)

        XCTAssertEqual(result, .unavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: remoteMeetingsRoot.path))
    }

    private var remoteMeetingsRoot: URL {
        containerRoot.appendingPathComponent("Meetings", isDirectory: true)
    }

    private var remoteTombstonesRoot: URL {
        containerRoot.appendingPathComponent("DeletedMeetings", isDirectory: true)
    }

    private func makeEngine() -> ICloudMeetingSyncEngine {
        ICloudMeetingSyncEngine(
            localMeetingsRoot: localMeetingsRoot,
            localTombstonesRoot: localTombstonesRoot,
            coordinatesRemoteAccess: false
        )
    }

    @discardableResult
    private func writeMeeting(
        id: UUID = UUID(),
        title: String,
        startedAt: Date,
        to root: URL
    ) throws -> Meeting {
        let meeting = Meeting(id: id, title: title, kind: .manual, startedAt: startedAt, duration: 60)
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try writeMetadata(meeting, to: root)
        try Data("audio".utf8).write(to: directory.appendingPathComponent("mix.m4a"))
        return meeting
    }

    private func writeMetadata(_ meeting: Meeting, to root: URL, modifiedAt: Date? = nil) throws {
        let url = root
            .appendingPathComponent(meeting.id.uuidString, isDirectory: true)
            .appendingPathComponent("meeting.json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meeting).write(to: url, options: .atomic)
        if let modifiedAt {
            try setModificationDate(modifiedAt, of: url)
        }
    }

    private func setModificationDate(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// Inode number: a file that was copied again is a different one even when the bytes match.
    private func fileIdentity(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.systemFileNumber] as? Int)
    }

    private func readMeeting(id: UUID, from root: URL) throws -> Meeting {
        let data = try Data(contentsOf: root
            .appendingPathComponent(id.uuidString)
            .appendingPathComponent("meeting.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Meeting.self, from: data)
    }

    private func meetingIDs(in root: URL) throws -> Set<UUID> {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).compactMap { UUID(uuidString: $0.lastPathComponent) })
    }
}
