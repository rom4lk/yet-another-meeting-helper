import AVFoundation
import Carbon.HIToolbox
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppController: ObservableObject {
    let settings = AppSettings()
    let store = MeetingStore()
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
        case preparing
        case installed
        case failed(String)
    }

    private let engine = TranscriptionEngine()
    private var preparingModel: String?
    private let panelController = FloatingPanelController()
    private var hotkeys: [GlobalHotkey] = []
    private var sessionObserver: AnyCancellable?
    private var storeObserver: AnyCancellable?

    var isRecording: Bool { session != nil }
    var isPanelVisible: Bool { panelController.isVisible }

    init() {
        // MeetingStore is a nested ObservableObject, so its changes have to be forwarded
        // for views that observe only the controller.
        storeObserver = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // MARK: - Bootstrap

    func bootstrap() {
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
                try await engine.prepare(model: model) { fraction in
                    Task { @MainActor in
                        guard self.settings.model == model else { return }
                        self.modelState = fraction < 1 ? .downloading(fraction) : .preparing
                    }
                }
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

    private func preloadInstalledModel() {
        guard settings.liveTranscriptEnabled else { return }
        guard preparingModel == nil else { return }

        let model = settings.model
        guard TranscriptionEngine.isDownloaded(model) else { return }

        preparingModel = model
        modelState = .preparing
        Task {
            do {
                try await engine.prepare(model: model)
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
        guard session == nil else { return }

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            requestMicrophonePermission()
            errorMessage = "No microphone access. Grant the permission and start recording again."
            detector.clearCurrent()
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
        }
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
}
