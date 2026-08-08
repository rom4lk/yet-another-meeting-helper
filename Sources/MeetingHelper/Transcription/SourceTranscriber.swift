import Foundation

enum SourceTranscriptionUpdate: Sendable {
    case preview(TranscriptLine)
    case final(TranscriptLine)
    case removePreview(UUID)
}

/// Turns a continuous 16 kHz mono stream into transcript lines.
///
/// Whisper is not a streaming model, so we cut the stream into utterances with a simple energy
/// VAD and transcribe each utterance on its own. One instance per track.
///
/// `feed` is called from the track writer's queue and every mutable field below is touched only
/// on `queue`, so instances are safe to hand to a capture callback.
final class SourceTranscriber: @unchecked Sendable {
    private enum Constants {
        static let sampleRate: Double = AudioTrackWriter.sampleRate
        static let frameSize = EchoReference.frameSize  // 100 ms
        static let preRollFrames = 3                    // 300 ms kept before speech onset
        static let silenceFramesToClose = 8             // 800 ms of silence ends an utterance
        static let minSpeechFrames = 4                  // shorter bursts are noise
        static let maxUtteranceFrames = 250             // hard cut at 25 s
        static let previewIntervalFrames = 20           // refresh the active phrase every 2 s
        static let absoluteThreshold: Float = 0.006
        static let noiseMultiplier: Float = 3.5
        /// How long an utterance waits for the system track to reach it before giving up.
        static let referenceWaitLimit: TimeInterval = 0.5
        static let referencePollInterval: UInt64 = 50_000_000
    }

    private let source: TranscriptSource
    private let transcribe: @Sendable ([Float], String?) async -> String?
    private let onUpdate: @MainActor (SourceTranscriptionUpdate) -> Void
    private let queue: DispatchQueue
    private let realtimeUpdatesEnabled: Bool
    private let echoReference: EchoReference?
    /// Reports every echo-gate decision so the recording UI can show that the gate is working.
    private let onEchoVerdict: (@MainActor (EchoVerdict) -> Void)?

    private var language: String?

    private var inbox: [Float] = []
    private var preRoll: [[Float]] = []
    private var pending: [Float] = []
    /// Per-frame loudness of `pending` and `preRoll`, kept for the echo gate.
    private var preRollEnergies: [Float] = []
    private var pendingEnergies: [Float] = []
    private var inUtterance = false
    private var speechFrames = 0
    private var silenceFrames = 0
    private var utteranceStartFrame = 0
    private var framesSeen = 0
    private var noiseFloor: Float = 0.002
    private var utteranceID: UUID?
    private var lastPreviewFrameCount = 0
    private var previewGeneration = 0
    private var activePreviewGeneration: Int?
    private var activePreviewTask: Task<Void, Never>?
    /// In-flight transcription tasks, only ever touched on `queue`. Each one drops its own entry
    /// when it finishes, so a long meeting does not accumulate a handle per utterance.
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var nextTaskID = 0

    init(
        source: TranscriptSource,
        language: String?,
        realtimeUpdatesEnabled: Bool,
        echoReference: EchoReference? = nil,
        onEchoVerdict: (@MainActor (EchoVerdict) -> Void)? = nil,
        transcribe: @escaping @Sendable ([Float], String?) async -> String?,
        onUpdate: @escaping @MainActor (SourceTranscriptionUpdate) -> Void
    ) {
        self.source = source
        self.transcribe = transcribe
        self.language = language
        self.realtimeUpdatesEnabled = realtimeUpdatesEnabled
        self.echoReference = echoReference
        self.onEchoVerdict = onEchoVerdict
        self.onUpdate = onUpdate
        self.queue = DispatchQueue(label: "com.kovalev.MeetingHelper.vad.\(source.rawValue)", qos: .utility)
    }

    convenience init(
        source: TranscriptSource,
        engine: any SpeechTranscribing,
        model: String,
        language: String?,
        realtimeUpdatesEnabled: Bool,
        echoReference: EchoReference? = nil,
        onEchoVerdict: (@MainActor (EchoVerdict) -> Void)? = nil,
        onUpdate: @escaping @MainActor (SourceTranscriptionUpdate) -> Void
    ) {
        self.init(
            source: source,
            language: language,
            realtimeUpdatesEnabled: realtimeUpdatesEnabled,
            echoReference: echoReference,
            onEchoVerdict: onEchoVerdict,
            transcribe: { samples, language in
                await engine.transcribe(samples, language: language, model: model)
            },
            onUpdate: onUpdate
        )
    }

    func feed(_ samples: [Float]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.inbox.append(contentsOf: samples)
            while self.inbox.count >= Constants.frameSize {
                let frame = Array(self.inbox.prefix(Constants.frameSize))
                self.inbox.removeFirst(Constants.frameSize)
                self.consume(frame)
            }
        }
    }

    /// Flushes whatever is still buffered and, when recognition is ready, waits for every
    /// in-flight transcription so the saved transcript is complete. If the model is still
    /// loading, pending work is discarded so stopping a recording does not wait for the model.
    func finish(waitForTranscription: Bool) async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { return continuation.resume() }

                guard waitForTranscription else {
                    self.activePreviewTask?.cancel()
                    self.activePreviewTask = nil
                    self.activePreviewGeneration = nil
                    self.inbox.removeAll()
                    self.pending.removeAll()
                    self.pendingEnergies.removeAll()
                    self.preRoll.removeAll()
                    self.preRollEnergies.removeAll()
                    self.utteranceID = nil
                    self.tasks.values.forEach { $0.cancel() }
                    self.tasks.removeAll()
                    return continuation.resume()
                }

                if !self.inbox.isEmpty {
                    self.pending.append(contentsOf: self.inbox)
                    self.inbox.removeAll()
                }
                self.closeUtterance(force: true)
                continuation.resume()
            }
        }

        let pending = queue.sync { Array(tasks.values) }
        for task in pending {
            await task.value
        }
    }

    /// Runs a transcription task and forgets the handle once it completes.
    private func track(_ body: @escaping @Sendable () async -> Void) {
        let id = nextTaskID
        nextTaskID += 1
        tasks[id] = Task { [weak self, queue] in
            await body()
            guard let self else { return }
            queue.async { self.tasks[id] = nil }
        }
    }

    private func consume(_ frame: [Float]) {
        framesSeen += 1

        let energy = rootMeanSquare(frame)
        // Track the quietest recent level as the noise floor so the threshold follows the room.
        if energy < noiseFloor {
            noiseFloor = noiseFloor * 0.9 + energy * 0.1
        } else {
            noiseFloor = noiseFloor * 0.995 + energy * 0.005
        }

        let threshold = max(Constants.absoluteThreshold, noiseFloor * Constants.noiseMultiplier)
        let isSpeech = energy > threshold

        if inUtterance {
            pending.append(contentsOf: frame)
            pendingEnergies.append(energy)
            if isSpeech {
                speechFrames += 1
                silenceFrames = 0
            } else {
                silenceFrames += 1
            }

            let frameCount = pending.count / Constants.frameSize
            if silenceFrames >= Constants.silenceFramesToClose || frameCount >= Constants.maxUtteranceFrames {
                closeUtterance(force: false)
            } else {
                startPreviewIfNeeded()
            }
        } else {
            preRoll.append(frame)
            preRollEnergies.append(energy)
            if preRoll.count > Constants.preRollFrames {
                preRoll.removeFirst()
                preRollEnergies.removeFirst()
            }

            guard isSpeech else { return }

            inUtterance = true
            utteranceID = UUID()
            utteranceStartFrame = framesSeen - preRoll.count
            pending = preRoll.flatMap { $0 }
            pendingEnergies = preRollEnergies
            preRoll.removeAll()
            preRollEnergies.removeAll()
            speechFrames = 1
            silenceFrames = 0
            lastPreviewFrameCount = 0
        }
    }

    private func closeUtterance(force: Bool) {
        let previewTask = activePreviewTask
        previewTask?.cancel()
        activePreviewTask = nil
        activePreviewGeneration = nil

        defer {
            inUtterance = false
            utteranceID = nil
            pending.removeAll()
            pendingEnergies.removeAll()
            preRoll.removeAll()
            preRollEnergies.removeAll()
            speechFrames = 0
            silenceFrames = 0
            lastPreviewFrameCount = 0
        }

        guard inUtterance, let utteranceID else { return }
        guard force || speechFrames >= Constants.minSpeechFrames else {
            schedulePreviewRemoval(utteranceID, after: previewTask)
            return
        }
        guard speechFrames > 0, !pending.isEmpty else {
            schedulePreviewRemoval(utteranceID, after: previewTask)
            return
        }

        let samples = pending
        let energies = pendingEnergies
        let offset = Double(utteranceStartFrame) * Double(Constants.frameSize) / Constants.sampleRate
        let source = self.source
        let language = self.language

        track { [transcribe, onUpdate, onEchoVerdict, echoReference] in
            if let previewTask {
                await previewTask.value
            }
            guard !Task.isCancelled else { return }
            if let echoReference {
                let verdict = await Self.verdict(for: energies, at: offset, reference: echoReference)
                await onEchoVerdict?(verdict)
                if verdict == .echo {
                    Log.audio.info("Dropped speaker leakage at \(offset, privacy: .public) s")
                    await onUpdate(.removePreview(utteranceID))
                    return
                }
            }
            guard let text = await transcribe(samples, language) else {
                await onUpdate(.removePreview(utteranceID))
                return
            }
            guard !Task.isCancelled else { return }
            let line = TranscriptLine(id: utteranceID, source: source, offset: offset, text: text)
            await onUpdate(.final(line))
        }
    }

    /// Recognizes an expanding snapshot of the active utterance. Every snapshot overlaps the
    /// previous one, letting Whisper revise the preview as more context arrives.
    private func startPreviewIfNeeded() {
        guard realtimeUpdatesEnabled, inUtterance, activePreviewTask == nil,
              let utteranceID
        else { return }

        let frameCount = pending.count / Constants.frameSize
        guard frameCount >= lastPreviewFrameCount + Constants.previewIntervalFrames else { return }

        let samples = pending
        let energies = pendingEnergies
        let offset = Double(utteranceStartFrame) * Double(Constants.frameSize) / Constants.sampleRate
        let source = self.source
        let language = self.language
        let queue = self.queue

        lastPreviewFrameCount = frameCount
        previewGeneration += 1
        let generation = previewGeneration
        activePreviewGeneration = generation

        let task = Task { [weak self, transcribe, onUpdate, echoReference] in
            if let echoReference {
                let verdict = await Self.verdict(for: energies, at: offset, reference: echoReference)
                guard !Task.isCancelled else {
                    queue.async { [weak self] in self?.previewDidFinish(generation) }
                    return
                }
                if verdict == .echo {
                    await onUpdate(.removePreview(utteranceID))
                    queue.async { [weak self] in self?.previewDidFinish(generation) }
                    return
                }
            }

            if let text = await transcribe(samples, language), !Task.isCancelled {
                let line = TranscriptLine(id: utteranceID, source: source, offset: offset, text: text)
                await onUpdate(.preview(line))
            }
            queue.async { [weak self] in self?.previewDidFinish(generation) }
        }
        activePreviewTask = task
    }

    private func previewDidFinish(_ generation: Int) {
        guard activePreviewGeneration == generation else { return }
        activePreviewTask = nil
        activePreviewGeneration = nil
        startPreviewIfNeeded()
    }

    private func schedulePreviewRemoval(_ id: UUID, after previewTask: Task<Void, Never>?) {
        track { [onUpdate] in
            if let previewTask {
                await previewTask.value
            }
            guard !Task.isCancelled else { return }
            await onUpdate(.removePreview(id))
        }
    }

    /// Waits for the system track to reach the end of the utterance, then asks the gate.
    ///
    /// Everything short of a confident echo verdict passes through — no reference, a window that
    /// scrolled out of the buffer, coverage that never arrives. Transcript deduplication is the
    /// second net, and dropping real speech is the worse failure.
    private static func verdict(
        for energies: [Float],
        at offset: TimeInterval,
        reference: EchoReference
    ) async -> EchoVerdict {
        guard energies.count >= EchoGate.minimumFrames, reference.hasData else { return .undecided }

        let lagSpan = Double(EchoGate.maximumLagFrames) * EchoReference.frameDuration
        let start = offset - lagSpan
        guard start >= 0 else { return .undecided }

        let end = offset + Double(energies.count) * EchoReference.frameDuration
        let deadline = Date().addingTimeInterval(Constants.referenceWaitLimit)
        while reference.coveredUntil < end {
            guard Date() < deadline else { return .undecided }
            try? await Task.sleep(nanoseconds: Constants.referencePollInterval)
        }

        guard let window = reference.envelope(
            startingAt: start,
            frameCount: energies.count + EchoGate.maximumLagFrames
        ) else { return .undecided }

        return EchoGate.isEcho(microphone: energies, reference: window) ? .echo : .speech
    }

}
