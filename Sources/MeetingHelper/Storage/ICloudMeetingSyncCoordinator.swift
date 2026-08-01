import Combine
import Foundation

@MainActor
final class ICloudMeetingSyncCoordinator: ObservableObject {
    enum Status: Equatable {
        case disabled
        case folderNotSelected
        case syncing
        case upToDate
        case unavailable
        case failed(String)
    }

    @Published private(set) var status: Status = .disabled

    var onLocalLibraryChange: (() -> Void)?

    private let engine: ICloudMeetingSyncEngine
    private var currentLimit: AppSettings.ICloudSyncLimit = .disabled
    private var currentFolderURL: URL?
    private var syncTask: Task<Void, Never>?
    private var resyncRequested = false
    private var syncGeneration = 0
    private var pollingTimer: Timer?

    init(engine: ICloudMeetingSyncEngine = ICloudMeetingSyncEngine()) {
        self.engine = engine
    }

    deinit {
        syncTask?.cancel()
        pollingTimer?.invalidate()
    }

    func update(limit: AppSettings.ICloudSyncLimit, folderURL: URL?) {
        let folderChanged = currentFolderURL != folderURL
        currentLimit = limit
        currentFolderURL = folderURL

        if folderChanged {
            cancelCurrentSync()
        }

        guard limit != .disabled else {
            stopSyncing()
            status = .disabled
            return
        }
        guard folderURL != nil else {
            stopSyncing()
            status = .folderNotSelected
            return
        }

        startPolling()
        scheduleSync()
    }

    func handleLocalLibraryChange(_ change: MeetingStore.LibraryChange) {
        switch change {
        case .updated:
            guard currentLimit != .disabled, currentFolderURL != nil else { return }
            scheduleSync()

        case .deleted(let meetingID):
            Task { [weak self, engine] in
                do {
                    try await engine.recordDeletion(of: meetingID)
                    guard let self,
                          self.currentLimit != .disabled,
                          self.currentFolderURL != nil else { return }
                    self.scheduleSync()
                } catch {
                    Log.store.error("Cannot record synchronized deletion: \(error, privacy: .public)")
                }
            }
        }
    }

    func applicationDidBecomeActive() {
        guard currentLimit != .disabled, currentFolderURL != nil else { return }
        scheduleSync()
    }

    private func scheduleSync() {
        guard currentLimit != .disabled, currentFolderURL != nil else { return }
        status = .syncing

        if syncTask != nil {
            resyncRequested = true
            return
        }

        let generation = syncGeneration
        syncTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            await self?.runSyncLoop(generation: generation)
        }
    }

    private func runSyncLoop(generation: Int) async {
        repeat {
            resyncRequested = false
            await synchronizeOnce()
        } while generation == syncGeneration
            && resyncRequested
            && currentLimit != .disabled
            && currentFolderURL != nil
            && !Task.isCancelled
        if generation == syncGeneration {
            syncTask = nil
        }
    }

    private func synchronizeOnce() async {
        guard let folderURL = currentFolderURL else {
            status = .folderNotSelected
            return
        }
        let limit = currentLimit

        do {
            let outcome = try await engine.synchronize(limit: limit, folderURL: folderURL)
            guard !Task.isCancelled,
                  currentLimit == limit,
                  currentFolderURL == folderURL else { return }

            switch outcome {
            case .synchronized(let localLibraryChanged):
                if localLibraryChanged {
                    onLocalLibraryChange?()
                }
                status = .upToDate
            case .unavailable:
                status = .unavailable
            }
        } catch is CancellationError {
            return
        } catch {
            status = .failed(error.localizedDescription)
            Log.store.error("Meeting folder sync failed: \(error, privacy: .public)")
        }
    }

    private func startPolling() {
        guard pollingTimer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSync() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollingTimer = timer
    }

    private func stopSyncing() {
        cancelCurrentSync()
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    private func cancelCurrentSync() {
        syncGeneration += 1
        syncTask?.cancel()
        syncTask = nil
        resyncRequested = false
    }
}
