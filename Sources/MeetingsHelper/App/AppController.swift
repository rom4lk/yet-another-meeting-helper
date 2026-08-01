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
        case installed
        case failed(String)
    }

    private let engine = TranscriptionEngine()
    private var downloadingModel: String?
    private let panelController = FloatingPanelController()
    private var hotkeys: [GlobalHotkey] = []
    private var sessionObserver: AnyCancellable?

    var isRecording: Bool { session != nil }
    var isPanelVisible: Bool { panelController.isVisible }

    // MARK: - Bootstrap

    func bootstrap() {
        detector.onStart = { [weak self] meeting in
            self?.startRecording(for: meeting)
        }
        detector.onStop = { [weak self] in
            self?.stopRecording(manually: false)
        }
        detector.autoDetectionEnabled = settings.autoDetectionEnabled

        registerHotkeys()
        refreshPermissions()
    }

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
        if !WindowTitles.requestTrust() {
            WindowTitles.openSystemSettings()
        }
        refreshPermissions()
    }

    // MARK: - Transcription model

    /// Pulls the model down (and into memory) ahead of time, so the first meeting does not spend
    /// its opening minutes downloading.
    func downloadModel() {
        guard downloadingModel == nil else { return }
        let model = settings.model
        downloadingModel = model
        modelState = .downloading(nil)

        Task {
            do {
                try await engine.prepare(model: model) { fraction in
                    Task { @MainActor in
                        guard self.settings.model == model else { return }
                        self.modelState = .downloading(fraction)
                    }
                }
                downloadingModel = nil
                refreshModelState()
            } catch {
                downloadingModel = nil
                if settings.model == model {
                    modelState = .failed(error.localizedDescription)
                } else {
                    refreshModelState()
                }
            }
        }
    }

    /// Reads the state off disk, so a model downloaded in an earlier launch is recognised.
    func refreshModelState() {
        guard downloadingModel != settings.model else { return }
        modelState = TranscriptionEngine.isDownloaded(settings.model) ? .installed : .missing
    }

    func selectModel(_ model: String) {
        settings.model = model
        refreshModelState()
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
            store.save(meeting)
            store.saveTranscript(lines, for: meeting.id)

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
