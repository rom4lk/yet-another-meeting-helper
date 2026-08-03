import Foundation
import os

enum ICloudMeetingSyncOutcome: Equatable {
    case synchronized(localLibraryChanged: Bool)
    case unavailable
}

/// Cancellation that survives leaving the cooperative thread pool.
///
/// Synchronisation runs on a private queue, where `Task.isCancelled` always reads false, so the
/// calling task's cancellation is mirrored into this flag for the work to poll instead.
private final class CancellationFlag: Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    func cancel() {
        cancelled.withLock { $0 = true }
    }

    func check() throws {
        if cancelled.withLock({ $0 }) { throw CancellationError() }
    }
}

/// Mirrors complete, finished meeting directories into a user-selected sync folder, typically in
/// iCloud Drive. Local storage remains the working copy so recording never depends on the network.
///
/// The work is file I/O that can block for minutes on a cold iCloud folder, so it runs on a
/// private serial queue instead of Swift's cooperative pool, where it would hold on to one of the
/// few threads shared with transcription. The queue being serial keeps a recorded deletion from
/// interleaving with a reconciliation.
///
/// `@unchecked Sendable`: the stored objects below are immutable references touched only from
/// that queue.
final class ICloudMeetingSyncEngine: @unchecked Sendable {
    private struct Record {
        let meeting: Meeting
        let directory: URL
        let modifiedAt: Date
    }

    private let localMeetingsRoot: URL
    private let localTombstonesRoot: URL
    private let coordinatesRemoteAccess: Bool
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.kovalev.MeetingHelper.sync", qos: .utility)

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

    func recordDeletion(of meetingID: UUID) async throws {
        try await onQueue { _ in
            try self.fileManager.createDirectory(
                at: self.localTombstonesRoot,
                withIntermediateDirectories: true
            )
            try Data().write(
                to: self.tombstoneURL(for: meetingID, in: self.localTombstonesRoot),
                options: .atomic
            )
        }
    }

    func synchronize(
        limit: AppSettings.ICloudSyncLimit,
        folderURL: URL
    ) async throws -> ICloudMeetingSyncOutcome {
        try await onQueue { cancellation in
            try self.synchronize(limit: limit, folderURL: folderURL, cancellation: cancellation)
        }
    }

    /// Runs `body` on the private queue, mirroring the calling task's cancellation into a flag the
    /// work can poll between steps.
    private func onQueue<Value: Sendable>(
        _ body: @escaping @Sendable (CancellationFlag) throws -> Value
    ) async throws -> Value {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result { try body(cancellation) })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func synchronize(
        limit: AppSettings.ICloudSyncLimit,
        folderURL: URL,
        cancellation: CancellationFlag
    ) throws -> ICloudMeetingSyncOutcome {
        guard limit != .disabled else {
            return .synchronized(localLibraryChanged: false)
        }
        try cancellation.check()

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
            remoteTombstonesRoot: remoteTombstonesRoot,
            cancellation: cancellation
        )
        try cancellation.check()

        var localRecords = records(in: localMeetingsRoot, coordinateReads: false)
        var remoteRecords = records(
            in: remoteMeetingsRoot,
            coordinateReads: coordinatesRemoteAccess
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
            try cancellation.check()
            try removeRemoteItem(at: record.directory)
        }

        var localLibraryChanged = tombstoneResult.localLibraryChanged
        for meetingID in retainedIDs {
            try cancellation.check()
            let local = localRecords[meetingID]
            let remote = remoteRecords[meetingID]

            switch (local, remote) {
            case (.some(let local), .none):
                let destination = remoteMeetingsRoot.appendingPathComponent(
                    meetingID.uuidString,
                    isDirectory: true
                )
                try mirrorDirectory(
                    at: destination,
                    from: local.directory,
                    coordinateSourceRead: false,
                    coordinateDestinationWrite: coordinatesRemoteAccess,
                    cancellation: cancellation
                )

            case (.none, .some(let remote)):
                let destination = localMeetingsRoot.appendingPathComponent(
                    meetingID.uuidString,
                    isDirectory: true
                )
                try mirrorDirectory(
                    at: destination,
                    from: remote.directory,
                    coordinateSourceRead: coordinatesRemoteAccess,
                    coordinateDestinationWrite: false,
                    cancellation: cancellation
                )
                localLibraryChanged = true

            case (.some(let local), .some(let remote)):
                if local.modifiedAt > remote.modifiedAt {
                    try mirrorDirectory(
                        at: remote.directory,
                        from: local.directory,
                        coordinateSourceRead: false,
                        coordinateDestinationWrite: coordinatesRemoteAccess,
                        cancellation: cancellation
                    )
                } else if remote.modifiedAt > local.modifiedAt {
                    try mirrorDirectory(
                        at: local.directory,
                        from: remote.directory,
                        coordinateSourceRead: coordinatesRemoteAccess,
                        coordinateDestinationWrite: false,
                        cancellation: cancellation
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
        remoteTombstonesRoot: URL,
        cancellation: CancellationFlag
    ) throws -> TombstoneResult {
        var localIDs = tombstoneIDs(in: localTombstonesRoot)
        let remoteIDs = tombstoneIDs(in: remoteTombstonesRoot)

        for meetingID in localIDs.subtracting(remoteIDs) {
            try cancellation.check()
            try Data().write(
                to: tombstoneURL(for: meetingID, in: remoteTombstonesRoot),
                options: .atomic
            )
        }

        for meetingID in remoteIDs.subtracting(localIDs) {
            try cancellation.check()
            try Data().write(
                to: tombstoneURL(for: meetingID, in: localTombstonesRoot),
                options: .atomic
            )
            localIDs.insert(meetingID)
        }

        var localLibraryChanged = false
        for meetingID in localIDs {
            try cancellation.check()
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

    private func records(in root: URL, coordinateReads: Bool) -> [UUID: Record] {
        let directories = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var result: [UUID: Record] = [:]
        for directory in directories {
            guard let meetingID = UUID(uuidString: directory.lastPathComponent) else { continue }
            let metadataURL = directory.appendingPathComponent("meeting.json")
            if coordinateReads, fileManager.isUbiquitousItem(at: directory) {
                try? fileManager.startDownloadingUbiquitousItem(at: directory)
            }
            guard let data = readData(at: metadataURL, coordinated: coordinateReads),
                  let meeting = try? decoder.decode(Meeting.self, from: data),
                  meeting.id == meetingID
            else { continue }

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

    /// Newest modification date among the files in the directory. Reading `meeting.json` alone
    /// would miss a transcript that changed while the metadata stayed exactly as it was, and the
    /// two copies would then compare as equal forever.
    private func contentModificationDate(in directory: URL) -> Date {
        let files = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return files.reduce(Date.distantPast) { newest, file in
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            return max(newest, values?.contentModificationDate ?? .distantPast)
        }
    }

    private func readData(at url: URL, coordinated: Bool) -> Data? {
        guard coordinated else { return try? Data(contentsOf: url) }

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
        guard coordinationError == nil, readError == nil else { return nil }
        return result
    }

    /// Brings `destination` in line with `source`, copying only the files that actually differ.
    ///
    /// A meeting directory is mostly audio that never changes once the recording is saved, so
    /// replacing the directory as a whole would re-upload the entire recording every time a title
    /// is edited. Writing the files in place also keeps the sync provider from seeing every file
    /// as brand new.
    private func mirrorDirectory(
        at destination: URL,
        from source: URL,
        coordinateSourceRead: Bool,
        coordinateDestinationWrite: Bool,
        cancellation: CancellationFlag
    ) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        if coordinateSourceRead {
            if fileManager.isUbiquitousItem(at: source) {
                try? fileManager.startDownloadingUbiquitousItem(at: source)
            }
            try coordinateReading(at: source) { coordinatedSource in
                try self.copyChangedFiles(
                    from: coordinatedSource,
                    to: destination,
                    cancellation: cancellation
                )
            }
        } else if coordinateDestinationWrite {
            try coordinateWriting(at: destination, options: .forMerging) {
                try self.copyChangedFiles(
                    from: source,
                    to: destination,
                    cancellation: cancellation
                )
            }
        } else {
            try copyChangedFiles(from: source, to: destination, cancellation: cancellation)
        }
    }

    /// A meeting directory holds a flat set of files, so a shallow comparison covers all of it.
    private func copyChangedFiles(
        from source: URL,
        to destination: URL,
        cancellation: CancellationFlag
    ) throws {
        let sourceFiles = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: Array(Self.comparedResourceKeys),
            options: [.skipsHiddenFiles]
        )

        for file in sourceFiles {
            try cancellation.check()
            let installed = destination.appendingPathComponent(file.lastPathComponent)
            guard !isUnchanged(file, installed) else { continue }
            try installFile(file, at: installed)
        }

        // A file the source no longer has must disappear from the mirror as well.
        let sourceNames = Set(sourceFiles.map(\.lastPathComponent))
        let installedFiles = (try? fileManager.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for file in installedFiles where !sourceNames.contains(file.lastPathComponent) {
            try cancellation.check()
            try fileManager.removeItem(at: file)
        }
    }

    private static let comparedResourceKeys: Set<URLResourceKey> = [
        .contentModificationDateKey,
        .fileSizeKey
    ]

    /// Size and modification date settle it: a file inside a meeting directory is written once and
    /// afterwards replaced whole, never edited in place, and copying preserves both values.
    private func isUnchanged(_ source: URL, _ destination: URL) -> Bool {
        guard let sourceValues = try? source.resourceValues(forKeys: Self.comparedResourceKeys),
              let destinationValues = try? destination.resourceValues(forKeys: Self.comparedResourceKeys),
              let sourceSize = sourceValues.fileSize,
              let destinationSize = destinationValues.fileSize,
              let sourceDate = sourceValues.contentModificationDate,
              let destinationDate = destinationValues.contentModificationDate
        else { return false }

        return sourceSize == destinationSize && sourceDate == destinationDate
    }

    /// Stages the copy on the destination's own volume first, so the visible file goes from the
    /// old contents to the new one in a single step.
    private func installFile(_ source: URL, at destination: URL) throws {
        let staging = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destination.deletingLastPathComponent(),
            create: true
        )
        defer { try? fileManager.removeItem(at: staging) }

        let staged = staging.appendingPathComponent(destination.lastPathComponent)
        try fileManager.copyItem(at: source, to: staged)

        guard fileManager.fileExists(atPath: destination.path) else {
            try fileManager.moveItem(at: staged, to: destination)
            return
        }
        // Without `.usingNewMetadataOnly` the installed file inherits the replaced file's
        // modification date, and the next reconciliation would find the copy stale all over again.
        _ = try fileManager.replaceItemAt(
            destination,
            withItemAt: staged,
            backupItemName: nil,
            options: [.usingNewMetadataOnly]
        )
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
