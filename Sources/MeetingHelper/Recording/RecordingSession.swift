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
        case downloading(Double?)
        case preparing(ModelPreparationStage)
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
    @Published private(set) var microphoneDeviceName = "Unknown microphone"
    @Published private(set) var micState: TrackState = .pending
    @Published private(set) var systemState: TrackState = .pending
    @Published private(set) var transcriptionState: TranscriptionState = .disabled
    @Published private(set) var lines: [TranscriptLine] = []
    /// The tap is active, but no audible system audio has been detected yet. This can mean that
    /// the meeting is quiet or, when permission is denied, that Core Audio is delivering silence.
    @Published private(set) var systemSilent = false
    /// Microphone utterances the echo gate was able to compare against the system track, and how
    /// many of those it recognized as speaker leakage. Utterances it could not judge count as
    /// neither: they pass through unchecked.
    @Published private(set) var echoGateChecked = 0
    @Published private(set) var echoGateFiltered = 0
    /// True for a few seconds after each drop, so the indicator visibly reacts.
    @Published private(set) var echoGateFiring = false

    private var lastEchoDropAt: Date?
    private var systemPeak: Float = 0
    private var captureStartedAtUptime: TimeInterval = 0

    private let settings: AppSettings
    private let engine: TranscriptionEngine
    private let transcriptDeduplicationEnabled: Bool
    private let realtimeTranscriptEnabled: Bool
    private var previewLineIDs: Set<UUID> = []

    private let microphone = MicrophoneCapture()
    /// The system track's loudness, used to recognize speaker leakage in the microphone.
    /// `nil` when the echo gate is off, which takes the whole check out of the path: nothing is
    /// buffered and no utterance ever waits for the system track before reaching Whisper.
    private let echoReference: EchoReference?
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
        self.transcriptDeduplicationEnabled = settings.transcriptDeduplicationEnabled
        self.realtimeTranscriptEnabled = settings.realtimeTranscriptEnabled
        self.echoReference = settings.echoGateEnabled ? EchoReference() : nil
        self.title = detected.title
    }

    // MARK: - Lifecycle

    func start() {
        startedAt = Date()
        captureStartedAtUptime = ProcessInfo.processInfo.systemUptime

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

    /// Stops every capture, finishes any ready transcription backlog and returns the saved meeting.
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

        let waitForTranscription = transcriptionState == .running
        await micTranscriber?.finish(waitForTranscription: waitForTranscription)
        await systemTranscriber?.finish(waitForTranscription: waitForTranscription)
        discardAllPreviews()
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
            _ = Mixdown.create(
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
            duration: duration,
            hasMicTrack: hasMic,
            hasSystemTrack: hasSystem
        )
    }

    var sortedLines: [TranscriptLine] {
        lines.sorted { $0.offset < $1.offset }
    }

    /// What the live views show. Unlike the other transcript options, this one is read on every
    /// access instead of being captured at init, so hiding or showing the microphone track takes
    /// effect during the recording. Saving uses `sortedLines`, so hidden lines are still stored.
    var visibleLines: [TranscriptLine] {
        guard settings.liveTranscriptShowsMySpeech else {
            return sortedLines.filter { $0.source != .me }
        }
        return sortedLines
    }

    var echoGateEnabled: Bool {
        echoReference != nil
    }

    var systemAudioSourceName: String {
        detected.audioSourceDisplayName
    }

    // MARK: - Sources

    // Capture callbacks run on Core Audio's threads, so they capture the writer and the
    // transcriber directly instead of reaching back through `self`. Those objects are internally
    // synchronised; this session's stored properties are main-actor state and must not be touched
    // from an audio thread.
    private func startMicrophone() {
        refreshMicrophoneDeviceName()

        do {
            let format = try microphone.prepare()
            let transcriber = micTranscriber
            let writer = try AudioTrackWriter(
                url: MeetingLibrary.micTrackURL(for: meetingID),
                sourceFormat: format,
                label: "mic",
                timelineStartUptime: captureStartedAtUptime
            ) { samples in
                transcriber?.feed(samples)
            }
            micWriter = writer

            try microphone.start { buffer in
                writer.append(buffer)
            }

            micState = .capturing
        } catch {
            Log.audio.error("Microphone failed: \(error, privacy: .public)")
            micState = .unavailable(error.localizedDescription)
        }
    }

    private func startSystemAudio() {
        // Core Audio only lists a process once it has touched audio, so right after a meeting
        // starts the conferencing app may not be there yet. Retry once a second for 15 seconds.
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
        let scope: SystemAudioTap.Scope
        if detected.capturesAllSystemAudio {
            let ownBundleID = Bundle.main.bundleIdentifier ?? "com.kovalev.MeetingHelper"
            let ownObjectIDs = AudioProcessLookup.matches(prefixes: [ownBundleID]).map(\.objectID)
            scope = .allSystemAudio(excluding: ownObjectIDs)
        } else {
            let objectIDs = AudioProcessLookup.matches(prefixes: detected.audioPrefixes).map(\.objectID)
            guard !objectIDs.isEmpty else { return false }
            scope = .processes(objectIDs)
        }

        let tap = SystemAudioTap(scope: scope)
        do {
            try tap.prepare()

            guard let format = tap.format else {
                systemState = .unavailable("System audio format unavailable")
                return true
            }

            let transcriber = systemTranscriber
            let reference = echoReference
            let writer = try AudioTrackWriter(
                url: MeetingLibrary.systemTrackURL(for: meetingID),
                sourceFormat: format,
                label: "system",
                timelineStartUptime: captureStartedAtUptime
            ) { samples in
                reference?.append(samples)
                transcriber?.feed(samples)
            }
            systemWriter = writer

            try tap.start { buffer in
                writer.append(buffer)
            }

            systemTap = tap
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

        let language = settings.language.whisperCode

        micTranscriber = SourceTranscriber(
            source: .me,
            engine: engine,
            language: language,
            realtimeUpdatesEnabled: realtimeTranscriptEnabled,
            echoReference: echoReference,
            onEchoVerdict: { [weak self] verdict in
                self?.receive(verdict)
            }
        ) { [weak self] update in
            self?.receive(update)
        }
        systemTranscriber = SourceTranscriber(
            source: .others,
            engine: engine,
            language: language,
            realtimeUpdatesEnabled: realtimeTranscriptEnabled
        ) { [weak self] update in
            self?.receive(update)
        }

        let model = settings.model
        transcriptionState = TranscriptionEngine.isDownloaded(model)
            ? .preparing(TranscriptionEngine.initialPreparationStage(for: model))
            : .downloading(nil)
        Task { [engine] in
            do {
                try await engine.prepare(
                    model: model,
                    onProgress: { [weak self] fraction in
                        Task { @MainActor in
                            self?.transcriptionState = fraction < 1
                                ? .downloading(fraction)
                                : .preparing(TranscriptionEngine.initialPreparationStage(for: model))
                        }
                    },
                    onPreparationStage: { [weak self] stage in
                        Task { @MainActor in
                            self?.transcriptionState = .preparing(stage)
                        }
                    }
                )
                transcriptionState = .running
            } catch {
                transcriptionState = .failed(error.localizedDescription)
            }
        }
    }

    private func receive(_ update: SourceTranscriptionUpdate) {
        switch update {
        case .preview(let line):
            previewLineIDs.insert(line.id)
            if let index = lines.firstIndex(where: { $0.id == line.id }) {
                lines[index] = line
            } else {
                lines.append(line)
            }
        case .final(let line):
            previewLineIDs.remove(line.id)
            lines.removeAll { $0.id == line.id }
            if transcriptDeduplicationEnabled {
                TranscriptDeduplicator.insert(line, into: &lines)
            } else {
                lines.append(line)
            }
        case .removePreview(let id):
            previewLineIDs.remove(id)
            lines.removeAll { $0.id == id }
        }
    }

    private func discardAllPreviews() {
        lines.removeAll { previewLineIDs.contains($0.id) }
        previewLineIDs.removeAll()
    }

    private func receive(_ verdict: EchoVerdict) {
        switch verdict {
        case .echo:
            echoGateChecked += 1
            echoGateFiltered += 1
            lastEchoDropAt = Date()
            echoGateFiring = true
        case .speech:
            echoGateChecked += 1
        case .undecided:
            break
        }
    }

    private func tick() {
        elapsed = Date().timeIntervalSince(startedAt)
        micLevel = micWriter?.level ?? 0
        systemLevel = systemWriter?.level ?? 0
        refreshMicrophoneDeviceName()

        if systemState == .pending, systemTap?.hasDeliveredAudio == true {
            systemState = .capturing
        }

        systemPeak = max(systemPeak, systemLevel)
        let systemIsAvailable: Bool
        if case .unavailable = systemState {
            systemIsAvailable = false
        } else {
            systemIsAvailable = true
        }
        systemSilent = systemIsAvailable && elapsed > 20 && systemPeak < 0.0005

        if let lastEchoDropAt, Date().timeIntervalSince(lastEchoDropAt) > 3 {
            echoGateFiring = false
        }
    }

    private func refreshMicrophoneDeviceName() {
        let detectedName = try? AudioObjectID.readDefaultInputDevice().readDeviceName()
        let name = detectedName.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown microphone"
        guard name != microphoneDeviceName else { return }

        microphoneDeviceName = name
    }
}
