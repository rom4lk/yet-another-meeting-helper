import AVFoundation
import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppController: ObservableObject {
    let settings = AppSettings()
    let store = MeetingStore()
    let iCloudSync = ICloudMeetingSyncCoordinator()
    let detector = MeetingDetector()

    @Published private(set) var session: RecordingSession?
    @Published private(set) var isStopping = false
    @Published var errorMessage: String?
    @Published private(set) var systemAudioPermission = SystemAudioPermission.status()
    @Published private(set) var accessibilityGranted = WindowTitles.isTrusted
    @Published private(set) var microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published private(set) var modelState: ModelState = .missing

    /// Availability of the transcription model on disk, as the settings screen shows it.
    enum ModelState: Equatable {
        case missing
        /// Fraction downloaded, `nil` until the first callback arrives.
        case downloading(Double?)
        case preparing(ModelPreparationStage)
        case installed
        case failed(String)
    }

    private let engine = TranscriptionEngine()
    private var preparingModel: String?
    private let panelController = FloatingPanelController()
    private var hotkeys: [GlobalHotkey] = []
    private var sessionObserver: AnyCancellable?
    private var storeObserver: AnyCancellable?
    private var iCloudSyncObserver: AnyCancellable?
    private var hasBootstrapped = false
    /// A meeting detected while the previous recording was still being finalised.
    private var pendingStart: DetectedMeeting?

    var isRecording: Bool { session != nil }
    var isPanelVisible: Bool { panelController.isVisible }

    init() {
        // MeetingStore is a nested ObservableObject, so its changes have to be forwarded
        // for views that observe only the controller.
        storeObserver = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        iCloudSyncObserver = iCloudSync.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        store.onLibraryChange = { [weak self] change in
            self?.iCloudSync.handleLocalLibraryChange(change)
        }
        iCloudSync.onLocalLibraryChange = { [weak self] in
            self?.store.reload()
        }
    }

    // MARK: - Bootstrap

    /// Runs once per launch. The main window is a `Window` scene, so closing it and reopening it
    /// from the menu bar calls `onAppear` again — and re-registering the hotkeys from there would
    /// hit `eventHotKeyExistsErr` for the still-live combinations, drop both registrations and
    /// leave the app with no working shortcuts.
    func bootstrap() {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-sidebar-recording-transition") {
            scheduleSidebarLayoutTestTransition()
            return
        }
#endif

        detector.onStart = { [weak self] meeting in
            self?.startRecording(for: meeting)
        }
        detector.onStop = { [weak self] in
            self?.stopRecording(manually: false)
        }
        detector.autoDetectionEnabled = settings.autoDetectionEnabled

        registerHotkeys()
        refreshPermissions()
        refreshModelState()
        preloadInstalledModel()
        iCloudSync.update(
            limit: settings.iCloudSyncLimit,
            folderURL: settings.iCloudSyncFolderURL
        )
    }

#if DEBUG
    private func scheduleSidebarLayoutTestTransition() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }

            let session = RecordingSession(
                detected: DetectedMeeting(
                    kind: .manual,
                    title: "UI Test Recording",
                    audioPrefixes: [],
                    detectedAt: Date()
                ),
                settings: settings,
                engine: engine
            )
            sessionObserver = session.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            self.session = session
        }
    }
#endif

    func refreshPermissions() {
        systemAudioPermission = SystemAudioPermission.status()
        accessibilityGranted = WindowTitles.isTrusted
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        Log.app.info("""
            Permissions — microphone: \(self.microphoneGranted, privacy: .public), \
            system audio: \(String(describing: self.systemAudioPermission), privacy: .public), \
            accessibility: \(self.accessibilityGranted, privacy: .public)
            """)
    }

    func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
    }

    func requestSystemAudioPermission() {
        SystemAudioPermission.request { status in
            Task { @MainActor in
                self.systemAudioPermission = status
                if status != .authorized {
                    SystemAudioPermission.openSystemSettings()
                }
            }
        }
    }

    func requestAccessibilityPermission() {
        refreshPermissions()
        guard !accessibilityGranted else { return }
        WindowTitles.openSystemSettings()
    }

    // MARK: - Transcription model

    /// Pulls the model down (and into memory) ahead of time, so the first meeting does not spend
    /// its opening minutes downloading.
    func downloadModel() {
        guard preparingModel == nil else { return }
        let model = settings.model
        preparingModel = model
        modelState = .downloading(nil)

        Task {
            do {
                try await engine.prepare(
                    model: model,
                    onProgress: { fraction in
                        Task { @MainActor in
                            guard self.settings.model == model else { return }
                            self.modelState = fraction < 1
                                ? .downloading(fraction)
                                : .preparing(TranscriptionEngine.initialPreparationStage(for: model))
                        }
                    },
                    onPreparationStage: { stage in
                        Task { @MainActor in
                            guard self.settings.model == model else { return }
                            self.modelState = .preparing(stage)
                        }
                    }
                )
                preparingModel = nil
                refreshModelState()
                if settings.model != model {
                    preloadInstalledModel()
                }
            } catch {
                preparingModel = nil
                if settings.model == model {
                    modelState = .failed(error.localizedDescription)
                } else {
                    refreshModelState()
                    preloadInstalledModel()
                }
            }
        }
    }

    /// Reads the state off disk, so a model downloaded in an earlier launch is recognised.
    func refreshModelState() {
        guard preparingModel != settings.model else { return }
        modelState = TranscriptionEngine.isDownloaded(settings.model) ? .installed : .missing
    }

    func selectModel(_ model: String) {
        settings.model = model
        refreshModelState()
        preloadInstalledModel()
    }

    func setLiveTranscriptEnabled(_ enabled: Bool) {
        settings.liveTranscriptEnabled = enabled
        if enabled {
            preloadInstalledModel()
        }
    }

    func setICloudSyncLimit(_ limit: AppSettings.ICloudSyncLimit) {
        settings.iCloudSyncLimit = limit
        iCloudSync.update(limit: limit, folderURL: settings.iCloudSyncFolderURL)
    }

    func chooseICloudSyncFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Sync Folder"
        panel.message = "Choose a folder in iCloud Drive or another file-syncing service."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.iCloudSyncFolderURL

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        guard !Self.pathsOverlap(folderURL, MeetingLibrary.root) else {
            errorMessage = "Choose a sync folder outside Meeting Helper's local meeting library."
            return
        }

        do {
            try settings.setICloudSyncFolderURL(folderURL)
            iCloudSync.update(limit: settings.iCloudSyncLimit, folderURL: folderURL)
        } catch {
            errorMessage = "Cannot save the sync folder: \(error.localizedDescription)"
        }
    }

    func clearICloudSyncFolder() {
        do {
            try settings.setICloudSyncFolderURL(nil)
            iCloudSync.update(limit: settings.iCloudSyncLimit, folderURL: nil)
        } catch {
            errorMessage = "Cannot clear the sync folder: \(error.localizedDescription)"
        }
    }

    func applicationDidBecomeActive() {
        refreshPermissions()
        iCloudSync.applicationDidBecomeActive()
    }

    private func preloadInstalledModel() {
        guard settings.liveTranscriptEnabled else { return }
        guard preparingModel == nil else { return }

        let model = settings.model
        guard TranscriptionEngine.isDownloaded(model) else { return }

        preparingModel = model
        modelState = .preparing(TranscriptionEngine.initialPreparationStage(for: model))
        Task {
            do {
                try await engine.prepare(model: model, onPreparationStage: { stage in
                    Task { @MainActor in
                        guard self.settings.model == model else { return }
                        self.modelState = .preparing(stage)
                    }
                })
                preparingModel = nil
                refreshModelState()
                if settings.model != model {
                    preloadInstalledModel()
                }
            } catch {
                preparingModel = nil
                if settings.model == model {
                    modelState = .failed(error.localizedDescription)
                } else {
                    refreshModelState()
                    preloadInstalledModel()
                }
            }
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startManualRecording()
        }
    }

    func startManualRecording() {
        guard session == nil else { return }
        if let meeting = detector.current {
            startRecording(for: meeting)
            return
        }
        detector.beginManual(title: "Recording \(Self.timeFormatter.string(from: Date()))")
    }

    private func startRecording(for meeting: DetectedMeeting) {
        // Stopping the previous recording drains the transcription backlog and writes the mixdown,
        // which can take a minute. Dropping a meeting detected in that window would lose it for
        // good: the detector has already recorded it as current and never fires `onStart` for it
        // again. Remember it instead and start once the previous session is gone.
        guard !isStopping else {
            pendingStart = meeting
            return
        }
        guard session == nil else { return }

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            // Keep the detector's state for an automatically detected meeting. Clearing it would
            // let the next poll fire `onStart` again two seconds later, raising this alert once
            // per poll for as long as the meeting runs. A manual recording has nothing to
            // re-detect, so its state is cleared to leave auto-detection free.
            if meeting.kind == .manual {
                detector.clearCurrent()
            }
            requestMicrophonePermission()
            errorMessage = "No microphone access. Grant the permission and start recording again."
            return
        }

        let session = RecordingSession(detected: meeting, settings: settings, engine: engine)
        // RecordingSession is a nested ObservableObject, so its changes have to be forwarded
        // for views that observe only the controller.
        sessionObserver = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        self.session = session
        session.start()

        if settings.showPanelOnStart, settings.liveTranscriptEnabled {
            showPanel()
        }
    }

    func stopRecording(manually: Bool = true) {
        guard let session, !isStopping else { return }
        isStopping = true

        Task {
            let meeting = await session.stop()
            let lines = session.sortedLines
            if meeting.shouldBeSaved(minimumDuration: TimeInterval(settings.minimumRecordingDuration)) {
                store.save(meeting)
                store.saveTranscript(lines, for: meeting.id)
            } else {
                store.delete(meeting)
            }

            self.session = nil
            self.sessionObserver = nil
            self.isStopping = false
            if manually, meeting.kind == .manual {
                self.detector.clearCurrent()
            }
            self.hidePanel()
            self.startPendingMeetingIfNeeded()
        }
    }

    /// Picks up a meeting that was detected while the previous recording was still stopping.
    /// The detector is the authority on whether it is still running: a short call can begin and
    /// end inside that window, and its `onStop` was swallowed by the stop already in flight.
    private func startPendingMeetingIfNeeded() {
        guard let pendingStart else { return }
        self.pendingStart = nil
        guard detector.current == pendingStart else { return }
        startRecording(for: pendingStart)
    }

    // MARK: - Floating panel

    func togglePanel() {
        panelController.isVisible ? hidePanel() : showPanel()
        objectWillChange.send()
    }

    func showPanel() {
        panelController.show(FloatingTranscriptView().environmentObject(self))
        objectWillChange.send()
    }

    func hidePanel() {
        panelController.hide()
        objectWillChange.send()
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        let toggleRecording = GlobalHotkey(
            keyCode: UInt32(kVK_ANSI_R),
            modifiers: UInt32(cmdKey | optionKey)
        ) { [weak self] in
            Task { @MainActor in self?.toggleRecording() }
        }

        let togglePanel = GlobalHotkey(
            keyCode: UInt32(kVK_ANSI_T),
            modifiers: UInt32(cmdKey | optionKey)
        ) { [weak self] in
            Task { @MainActor in self?.togglePanel() }
        }

        hotkeys = [toggleRecording, togglePanel].compactMap { $0 }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func pathsOverlap(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhsComponents = lhs.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let rhsComponents = rhs.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return lhsComponents.starts(with: rhsComponents) || rhsComponents.starts(with: lhsComponents)
    }
}
