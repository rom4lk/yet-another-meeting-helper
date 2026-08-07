import Foundation

enum ICloudMeetingSyncOutcome: Equatable {
    case synchronized(localLibraryChanged: Bool)
    case unavailable
}

private struct ICloudMeetingSyncMetadataError: LocalizedError {
    let metadataURL: URL
    let reason: String

    var errorDescription: String? {
        "Cannot read synchronized meeting metadata at \(metadataURL.path): \(reason)"
    }
}

/// Mirrors complete, finished meeting directories into a user-selected sync folder, typically in
/// iCloud Drive. Local storage remains the working copy so recording never depends on the network.
actor ICloudMeetingSyncEngine {
    private struct Record {
        let meeting: Meeting
        let directory: URL
        let modifiedAt: Date
    }

    private let localMeetingsRoot: URL
    private let localTombstonesRoot: URL
    private let coordinatesRemoteAccess: Bool
    private let fileManager = FileManager.default

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(
        localMeetingsRoot: URL = MeetingLibrary.root,
        localTombstonesRoot: URL = ICloudMeetingSyncEngine.defaultTombstonesRoot,
        coordinatesRemoteAccess: Bool = true
    ) {
        self.localMeetingsRoot = localMeetingsRoot
        self.localTombstonesRoot = localTombstonesRoot
        self.coordinatesRemoteAccess = coordinatesRemoteAccess
    }

    func recordDeletion(of meetingID: UUID) throws {
        try fileManager.createDirectory(at: localTombstonesRoot, withIntermediateDirectories: true)
        try Data().write(to: tombstoneURL(for: meetingID, in: localTombstonesRoot), options: .atomic)
    }

    func synchronize(
        limit: AppSettings.ICloudSyncLimit,
        folderURL: URL
    ) throws -> ICloudMeetingSyncOutcome {
        guard limit != .disabled else {
            return .synchronized(localLibraryChanged: false)
        }
        try Task.checkCancellation()

        var isDirectory: ObjCBool = false
        guard folderURL.isFileURL,
              fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .unavailable
        }

        let remoteMeetingsRoot = folderURL.appendingPathComponent("Meetings", isDirectory: true)
        let remoteTombstonesRoot = folderURL.appendingPathComponent(
            "DeletedMeetings",
            isDirectory: true
        )

        try fileManager.createDirectory(at: localMeetingsRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: localTombstonesRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: remoteMeetingsRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: remoteTombstonesRoot, withIntermediateDirectories: true)

        let tombstoneResult = try synchronizeTombstones(
            remoteMeetingsRoot: remoteMeetingsRoot,
            remoteTombstonesRoot: remoteTombstonesRoot
        )
        try Task.checkCancellation()

        var localRecords = try records(
            in: localMeetingsRoot,
            coordinateReads: false,
            allowsMissingMetadata: true
        )
        var remoteRecords = try records(
            in: remoteMeetingsRoot,
            coordinateReads: coordinatesRemoteAccess,
            allowsMissingMetadata: false
        )
        for meetingID in tombstoneResult.ids {
            localRecords.removeValue(forKey: meetingID)
            remoteRecords.removeValue(forKey: meetingID)
        }

        let retainedIDs = retainedMeetingIDs(
            localRecords: localRecords,
            remoteRecords: remoteRecords,
            maximumCount: limit.maximumMeetingCount
        )

        for (meetingID, record) in remoteRecords where !retainedIDs.contains(meetingID) {
            try Task.checkCancellation()
            try removeRemoteItem(at: record.directory)
        }

        var localLibraryChanged = tombstoneResult.localLibraryChanged
        for meetingID in retainedIDs {
            try Task.checkCancellation()
            let local = localRecords[meetingID]
            let remote = remoteRecords[meetingID]

            switch (local, remote) {
            case (.some(let local), .none):
                let destination = remoteMeetingsRoot.appendingPathComponent(
                    meetingID.uuidString,
                    isDirectory: true
                )
                try replaceDirectory(
                    at: destination,
                    with: local.directory,
                    coordinateSourceRead: false,
                    coordinateDestinationWrite: coordinatesRemoteAccess
                )

            case (.none, .some(let remote)):
                let destination = localMeetingsRoot.appendingPathComponent(
                    meetingID.uuidString,
                    isDirectory: true
                )
                try replaceDirectory(
                    at: destination,
                    with: remote.directory,
                    coordinateSourceRead: coordinatesRemoteAccess,
                    coordinateDestinationWrite: false
                )
                localLibraryChanged = true

            case (.some(let local), .some(let remote)):
                if local.modifiedAt > remote.modifiedAt {
                    try replaceDirectory(
                        at: remote.directory,
                        with: local.directory,
                        coordinateSourceRead: false,
                        coordinateDestinationWrite: coordinatesRemoteAccess
                    )
                } else if remote.modifiedAt > local.modifiedAt {
                    try replaceDirectory(
                        at: local.directory,
                        with: remote.directory,
                        coordinateSourceRead: coordinatesRemoteAccess,
                        coordinateDestinationWrite: false
                    )
                    localLibraryChanged = true
                }

            case (.none, .none):
                break
            }
        }

        return .synchronized(localLibraryChanged: localLibraryChanged)
    }

    private struct TombstoneResult {
        let ids: Set<UUID>
        let localLibraryChanged: Bool
    }

    private func synchronizeTombstones(
        remoteMeetingsRoot: URL,
        remoteTombstonesRoot: URL
    ) throws -> TombstoneResult {
        var localIDs = tombstoneIDs(in: localTombstonesRoot)
        let remoteIDs = tombstoneIDs(in: remoteTombstonesRoot)

        for meetingID in localIDs.subtracting(remoteIDs) {
            try Task.checkCancellation()
            try Data().write(
                to: tombstoneURL(for: meetingID, in: remoteTombstonesRoot),
                options: .atomic
            )
        }

        for meetingID in remoteIDs.subtracting(localIDs) {
            try Task.checkCancellation()
            try Data().write(
                to: tombstoneURL(for: meetingID, in: localTombstonesRoot),
                options: .atomic
            )
            localIDs.insert(meetingID)
        }

        var localLibraryChanged = false
        for meetingID in localIDs {
            try Task.checkCancellation()
            let localDirectory = localMeetingsRoot.appendingPathComponent(
                meetingID.uuidString,
                isDirectory: true
            )
            if fileManager.fileExists(atPath: localDirectory.path) {
                try fileManager.removeItem(at: localDirectory)
                localLibraryChanged = true
            }

            let remoteDirectory = remoteMeetingsRoot.appendingPathComponent(
                meetingID.uuidString,
                isDirectory: true
            )
            if fileManager.fileExists(atPath: remoteDirectory.path) {
                try removeRemoteItem(at: remoteDirectory)
            }
        }

        return TombstoneResult(ids: localIDs, localLibraryChanged: localLibraryChanged)
    }

    private func records(
        in root: URL,
        coordinateReads: Bool,
        allowsMissingMetadata: Bool
    ) throws -> [UUID: Record] {
        let directories = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var result: [UUID: Record] = [:]
        for directory in directories {
            guard let meetingID = UUID(uuidString: directory.lastPathComponent) else { continue }
            let metadataURL = directory.appendingPathComponent("meeting.json")
            if allowsMissingMetadata, !fileManager.fileExists(atPath: metadataURL.path) {
                continue
            }
            if coordinateReads, fileManager.isUbiquitousItem(at: directory) {
                try? fileManager.startDownloadingUbiquitousItem(at: directory)
            }
            let meeting: Meeting
            do {
                let data = try readData(at: metadataURL, coordinated: coordinateReads)
                meeting = try decoder.decode(Meeting.self, from: data)
            } catch {
                throw ICloudMeetingSyncMetadataError(
                    metadataURL: metadataURL,
                    reason: error.localizedDescription
                )
            }
            guard meeting.id == meetingID else {
                throw ICloudMeetingSyncMetadataError(
                    metadataURL: metadataURL,
                    reason: "the meeting ID does not match its directory name"
                )
            }

            result[meetingID] = Record(
                meeting: meeting,
                directory: directory,
                modifiedAt: contentModificationDate(in: directory)
            )
        }
        return result
    }

    private func retainedMeetingIDs(
        localRecords: [UUID: Record],
        remoteRecords: [UUID: Record],
        maximumCount: Int?
    ) -> Set<UUID> {
        let allIDs = Set(localRecords.keys).union(remoteRecords.keys)
        let sortedIDs = allIDs.sorted { lhs, rhs in
            let lhsMeeting = preferredRecord(localRecords[lhs], remoteRecords[lhs]).meeting
            let rhsMeeting = preferredRecord(localRecords[rhs], remoteRecords[rhs]).meeting
            if lhsMeeting.startedAt == rhsMeeting.startedAt {
                return lhs.uuidString < rhs.uuidString
            }
            return lhsMeeting.startedAt > rhsMeeting.startedAt
        }

        if let maximumCount {
            return Set(sortedIDs.prefix(maximumCount))
        }
        return Set(sortedIDs)
    }

    private func preferredRecord(_ local: Record?, _ remote: Record?) -> Record {
        switch (local, remote) {
        case (.some(let local), .some(let remote)):
            return remote.modifiedAt > local.modifiedAt ? remote : local
        case (.some(let local), .none):
            return local
        case (.none, .some(let remote)):
            return remote
        case (.none, .none):
            preconditionFailure("A retained meeting must have a local or remote record")
        }
    }

    private func contentModificationDate(in directory: URL) -> Date {
        let metadataURL = directory.appendingPathComponent("meeting.json")
        let values = try? metadataURL.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
    }

    private func readData(at url: URL, coordinated: Bool) throws -> Data {
        guard coordinated else { return try Data(contentsOf: url) }

        if fileManager.isUbiquitousItem(at: url) {
            try? fileManager.startDownloadingUbiquitousItem(at: url)
        }
        var result: Data?
        var readError: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) {
            coordinatedURL in
            do {
                result = try Data(contentsOf: coordinatedURL)
            } catch {
                readError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let readError { throw readError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return result
    }

    private func replaceDirectory(
        at destination: URL,
        with source: URL,
        coordinateSourceRead: Bool,
        coordinateDestinationWrite: Bool
    ) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }

        if coordinateSourceRead {
            if fileManager.isUbiquitousItem(at: source) {
                try? fileManager.startDownloadingUbiquitousItem(at: source)
            }
            try coordinateReading(at: source) { coordinatedSource in
                try fileManager.copyItem(at: coordinatedSource, to: staging)
            }
        } else {
            try fileManager.copyItem(at: source, to: staging)
        }

        let install = { try self.installStagedDirectory(staging, at: destination) }

        if coordinateDestinationWrite {
            let destinationExists = fileManager.fileExists(atPath: destination.path)
            try coordinateWriting(
                at: destinationExists ? destination : parent,
                options: destinationExists ? .forReplacing : .forMerging,
                accessor: install
            )
        } else {
            try install()
        }
    }

    private func removeRemoteItem(at url: URL) throws {
        guard coordinatesRemoteAccess else {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            return
        }
        try coordinateWriting(at: url, options: .forDeleting) {
            if self.fileManager.fileExists(atPath: url.path) {
                try self.fileManager.removeItem(at: url)
            }
        }
    }

    private func installStagedDirectory(_ staging: URL, at destination: URL) throws {
        guard fileManager.fileExists(atPath: destination.path) else {
            try fileManager.moveItem(at: staging, to: destination)
            return
        }

        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(".sync-backup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.moveItem(at: destination, to: backup)
        do {
            try fileManager.moveItem(at: staging, to: destination)
            try fileManager.removeItem(at: backup)
        } catch {
            if !fileManager.fileExists(atPath: destination.path),
               fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw error
        }
    }

    private func coordinateReading(at url: URL, accessor: (URL) throws -> Void) throws {
        var accessorError: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) {
            coordinatedURL in
            do {
                try accessor(coordinatedURL)
            } catch {
                accessorError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let accessorError { throw accessorError }
    }

    private func coordinateWriting(
        at url: URL,
        options: NSFileCoordinator.WritingOptions,
        accessor: () throws -> Void
    ) throws {
        var accessorError: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &coordinationError) {
            _ in
            do {
                try accessor()
            } catch {
                accessorError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let accessorError { throw accessorError }
    }

    private func tombstoneIDs(in root: URL) -> Set<UUID> {
        let files = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return Set(files.compactMap { file in
            guard file.pathExtension == "deleted" else { return nil }
            return UUID(uuidString: file.deletingPathExtension().lastPathComponent)
        })
    }

    private func tombstoneURL(for meetingID: UUID, in root: URL) -> URL {
        root.appendingPathComponent(meetingID.uuidString).appendingPathExtension("deleted")
    }

    private static let defaultTombstonesRoot: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingHelper", isDirectory: true)
            .appendingPathComponent("Sync", isDirectory: true)
            .appendingPathComponent("Tombstones", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
}
