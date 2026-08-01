import AVFoundation
import Foundation

/// A recording in progress: two capture sources, two files, two transcribers.
@MainActor
final class RecordingSession: ObservableObject {
    enum TrackState: Equatable {
        case pending
        case capturing
        case unavailable(String)
    }

    enum TranscriptionState: Equatable {
        case disabled
        case preparing
        case running
        case failed(String)
    }

    let meetingID = UUID()
    let detected: DetectedMeeting

    @Published var title: String
    @Published private(set) var startedAt = Date()
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var micState: TrackState = .pending
    @Published private(set) var systemState: TrackState = .pending
    @Published private(set) var transcriptionState: TranscriptionState = .disabled
    @Published private(set) var lines: [TranscriptLine] = []
    /// The tap reports success but nothing ever arrives — almost always a missing system audio
    /// permission, which Core Audio signals by handing out silence rather than an error.
    @Published private(set) var systemSilent = false

    private var systemPeak: Float = 0

    private let settings: AppSettings
    private let engine: TranscriptionEngine

    private let microphone = MicrophoneCapture()
    private var systemTap: SystemAudioTap?
    private var micWriter: AudioTrackWriter?
    private var systemWriter: AudioTrackWriter?
    private var micTranscriber: SourceTranscriber?
    private var systemTranscriber: SourceTranscriber?

    private var uiTimer: Timer?
    private var systemRetryTimer: Timer?
    private var systemRetriesLeft = 15

    init(detected: DetectedMeeting, settings: AppSettings, engine: TranscriptionEngine) {
        self.detected = detected
        self.settings = settings
        self.engine = engine
        self.title = detected.title
    }

    // MARK: - Lifecycle

    func start() {
        do {
            _ = try MeetingLibrary.createDirectory(for: meetingID)
        } catch {
            Log.audio.error("Cannot create meeting directory: \(error, privacy: .public)")
        }

        startTranscription()
        startMicrophone()
        startSystemAudio()

        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        uiTimer = timer
    }

    /// Stops every capture, waits for the transcription backlog and returns the saved meeting.
    func stop() async -> Meeting {
        uiTimer?.invalidate()
        uiTimer = nil
        systemRetryTimer?.invalidate()
        systemRetryTimer = nil

        microphone.stop()
        systemTap?.stop()
        systemTap = nil

        micWriter?.finish()
        systemWriter?.finish()

        await micTranscriber?.finish()
        await systemTranscriber?.finish()
        micTranscriber = nil
        systemTranscriber = nil

        let micDuration = micWriter?.duration ?? 0
        let systemDuration = systemWriter?.duration ?? 0
        let duration = max(micDuration, systemDuration, Date().timeIntervalSince(startedAt))

        let hasMic = micDuration > 0
        let hasSystem = systemDuration > 0

        micWriter = nil
        systemWriter = nil

        let id = meetingID
        await Task.detached(priority: .utility) {
            Mixdown.create(
                micURL: hasMic ? MeetingLibrary.micTrackURL(for: id) : nil,
                systemURL: hasSystem ? MeetingLibrary.systemTrackURL(for: id) : nil,
                outputURL: MeetingLibrary.mixdownURL(for: id)
            )
        }.value

        return Meeting(
            id: meetingID,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? detected.title : title,
            kind: detected.kind,
            startedAt: startedAt,
            endedAt: Date(),
            duration: duration,
            hasMicTrack: hasMic,
            hasSystemTrack: hasSystem
        )
    }

    var sortedLines: [TranscriptLine] {
        lines.sorted { $0.offset < $1.offset }
    }

    // MARK: - Sources

    private func startMicrophone() {
        do {
            try microphone.start { [weak self] buffer in
                self?.micWriter?.append(buffer)
            }

            guard let format = microphone.format else {
                micState = .unavailable("Microphone format unavailable")
                return
            }

            micWriter = try AudioTrackWriter(
                url: MeetingLibrary.micTrackURL(for: meetingID),
                sourceFormat: format,
                label: "mic"
            ) { [weak self] samples in
                self?.micTranscriber?.feed(samples)
            }

            micState = .capturing
        } catch {
            Log.audio.error("Microphone failed: \(error, privacy: .public)")
            micState = .unavailable(error.localizedDescription)
        }
    }

    private func startSystemAudio() {
        // Core Audio only lists a process once it has touched audio, so right after a meeting
        // starts the conferencing app may not be there yet. Retry for a few seconds.
        guard attachSystemTap() else {
            guard systemRetriesLeft > 0 else {
                systemState = .unavailable("Could not find the meeting app's audio stream")
                return
            }
            systemRetriesLeft -= 1
            let timer = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.startSystemAudio() }
            }
            RunLoop.main.add(timer, forMode: .common)
            systemRetryTimer = timer
            return
        }
    }

    private func attachSystemTap() -> Bool {
        let objectIDs = AudioProcessLookup.matches(prefixes: detected.audioPrefixes).map(\.objectID)
        guard !objectIDs.isEmpty else { return false }

        let tap = SystemAudioTap(processObjectIDs: objectIDs)
        do {
            try tap.start { [weak self] buffer in
                self?.systemWriter?.append(buffer)
            }

            guard let format = tap.format else {
                systemState = .unavailable("System audio format unavailable")
                return true
            }

            systemWriter = try AudioTrackWriter(
                url: MeetingLibrary.systemTrackURL(for: meetingID),
                sourceFormat: format,
                label: "system"
            ) { [weak self] samples in
                self?.systemTranscriber?.feed(samples)
            }

            systemTap = tap
            systemState = .capturing
            return true
        } catch {
            Log.audio.error("System tap failed: \(error, privacy: .public)")
            tap.stop()
            systemState = .unavailable(error.localizedDescription)
            return true
        }
    }

    private func startTranscription() {
        guard settings.liveTranscriptEnabled else {
            transcriptionState = .disabled
            return
        }

        transcriptionState = .preparing
        let language = settings.language.whisperCode

        micTranscriber = SourceTranscriber(source: .me, engine: engine, language: language) { [weak self] line in
            self?.lines.append(line)
        }
        systemTranscriber = SourceTranscriber(source: .others, engine: engine, language: language) { [weak self] line in
            self?.lines.append(line)
        }

        let model = settings.model
        Task { [engine] in
            do {
                try await engine.prepare(model: model)
                transcriptionState = .running
            } catch {
                transcriptionState = .failed(error.localizedDescription)
            }
        }
    }

    private func tick() {
        elapsed = Date().timeIntervalSince(startedAt)
        micLevel = micWriter?.level ?? 0
        systemLevel = systemWriter?.level ?? 0

        systemPeak = max(systemPeak, systemLevel)
        systemSilent = systemState == .capturing && elapsed > 20 && systemPeak < 0.0005
    }
}
