import Foundation
import FluidAudio
import WhisperKit

enum ModelPreparationStage: Equatable, Sendable {
    case optimizing
    case loading

    var statusText: String {
        switch self {
        case .optimizing:
            "Optimizing for Apple Neural Engine…"
        case .loading:
            "Loading model into memory…"
        }
    }

    var detailText: String {
        switch self {
        case .optimizing:
            "The first optimization can take 10 minutes or more. Later launches are usually much faster."
        case .loading:
            "This usually takes a few seconds."
        }
    }
}

protocol SpeechTranscribing: Sendable {
    func transcribe(_ samples: [Float], language: String?, model: String) async -> String?
}

/// Owns the selected speech recognition pipeline. Both tracks funnel their chunks through this
/// actor, and an explicit gate keeps the model serial even while the actor is reentrant at
/// suspension points.
actor TranscriptionEngine: SpeechTranscribing {
    enum State: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    static let repo = "argmaxinc/whisperkit-coreml"

    private static let downloadBase: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MeetingHelper", directoryHint: .isDirectory)
            .appending(path: "Models", directoryHint: .isDirectory)
    }()

    private static let migrateLegacyCache: Void = {
        let fileManager = FileManager.default
        let destination = HubApiWrapper(downloadBase: downloadBase)
            .localRepoLocation(HubApiWrapper.Repo(id: repo))
        guard !fileManager.fileExists(atPath: destination.path) else { return }

        let legacyBase = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "huggingface", directoryHint: .isDirectory)
        let source = HubApiWrapper(downloadBase: legacyBase)
            .localRepoLocation(HubApiWrapper.Repo(id: repo))
        guard fileManager.fileExists(atPath: source.path) else { return }

        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: source, to: destination)
            Log.asr.notice("Moved the WhisperKit model cache to Application Support")
        } catch {
            Log.asr.error("Could not move the legacy WhisperKit cache: \(error, privacy: .public)")
        }
    }()

    private(set) var state: State = .idle
    private var whisperKit: WhisperKit?
    private var parakeet: AsrManager?
    private var loadedModel: String?
    private var loadTask: Task<Void, Error>?
    private var loadingModel: String?
    private var failedModel: String?
    private var loadGeneration = 0
    private var preparationStage: ModelPreparationStage?
    private var preparationObservers: [UUID: (model: String, callback: @Sendable (ModelPreparationStage) -> Void)] = [:]
    private var transcriptionInProgress = false
    private var transcriptionWaiters: [CheckedContinuation<Void, Never>] = []

    /// Whisper reliably emits these when fed near-silence. Dropping them keeps the live
    /// transcript from filling up with phantom lines during quiet stretches.
    ///
    /// These are verbatim model outputs matched against, not interface text — they must stay in
    /// the language Whisper produces them in.
    private static let hallucinations: Set<String> = [
        "продолжение следует...",
        "субтитры сделал dimatorzok",
        "субтитры создавал dimatorzok",
        "редактор субтитров а.синецкая корректор а.егорова",
        "спасибо за просмотр!",
        "спасибо за внимание!",
        "thank you.",
        "thanks for watching!",
        "you",
        "bye.",
        "."
    ]

    /// Whether a recognised phrase is one of the known near-silence artefacts.
    static func isHallucination(_ text: String) -> Bool {
        hallucinations.contains(text.lowercased())
    }

    /// Whether every file required by the selected backend is already cached, so a download would
    /// be a no-op. Checking the full set matters because interrupted downloads leave partial model
    /// folders behind.
    static func isDownloaded(_ model: String) -> Bool {
        if model == AppSettings.parakeetModelID {
            return AsrModels.modelsExist(
                at: AsrModels.defaultCacheDirectory(for: .v3),
                version: .v3
            )
        }
        return downloadedModelFolder(model) != nil
    }

    private static func downloadedModelFolder(_ model: String) -> URL? {
        _ = migrateLegacyCache

        let currentFolder = HubApiWrapper(downloadBase: downloadBase)
            .localRepoLocation(HubApiWrapper.Repo(id: repo))
            .appending(path: model)
        if containsRequiredModels(currentFolder) {
            return currentFolder
        }

        // Keep the existing download usable if macOS prevented moving it out of Documents.
        let legacyBase = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "huggingface", directoryHint: .isDirectory)
        let legacyFolder = HubApiWrapper(downloadBase: legacyBase)
            .localRepoLocation(HubApiWrapper.Repo(id: repo))
            .appending(path: model)
        return containsRequiredModels(legacyFolder) ? legacyFolder : nil
    }

    private static func containsRequiredModels(_ folder: URL) -> Bool {
        return ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy { name in
            ["mlmodelc", "mlpackage"].contains { ext in
                FileManager.default.fileExists(atPath: folder.appending(path: "\(name).\(ext)").path)
            }
        }
    }

    /// Downloads the model if it is not cached yet, then loads it.
    ///
    /// - Parameter onProgress: fraction of the download when the backend exposes progress, `1`
    ///   once the bytes are in and the model is being loaded into memory. Never called for an
    ///   already cached model.
    func prepare(
        model: String,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        onPreparationStage: (@Sendable (ModelPreparationStage) -> Void)? = nil
    ) async throws {
        let observerID = UUID()
        if let onPreparationStage {
            preparationObservers[observerID] = (model, onPreparationStage)
            if loadingModel == model, let preparationStage {
                onPreparationStage(preparationStage)
            }
        }
        defer { preparationObservers[observerID] = nil }

        // Wait out a load already in flight — it may be for another model, in which case the
        // check below still sends us down the loading path.
        if let loadTask {
            let activeModel = loadingModel
            do {
                try await loadTask.value
            } catch {
                if activeModel == model { throw error }
            }
            // The task installs the model before it completes. Its initiating caller may not
            // have resumed yet to publish `.ready`, so do not start the same load a second time.
            if activeModel == model, hasLoadedModel(model) {
                if loadingModel == model {
                    state = .ready
                    loadedModel = model
                    failedModel = nil
                    self.loadTask = nil
                    loadingModel = nil
                    preparationStage = nil
                }
                return
            }
        }
        if case .ready = state, hasLoadedModel(model), loadedModel == model { return }

        if failedModel == model {
            failedModel = nil
        }
        state = .loading
        loadingModel = model
        loadGeneration += 1
        let generation = loadGeneration
        // The previously prepared model stays resident until the new one is in: a failed switch
        // must not leave an active recording with no recogniser at all.
        let task = Task<Void, Error> {
            if model == AppSettings.parakeetModelID {
                let models = try await AsrModels.downloadAndLoad(version: .v3) { progress in
                    onProgress?(progress.fractionCompleted)
                }
                publishPreparationStage(.loading, for: model)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                self.parakeet = manager
                self.whisperKit = nil
            } else {
                let folder: URL
                if let downloadedFolder = Self.downloadedModelFolder(model) {
                    folder = downloadedFolder
                } else {
                    folder = try await WhisperKit.download(
                        variant: model,
                        downloadBase: Self.downloadBase,
                        from: Self.repo
                    ) { progress in
                        onProgress?(progress.fractionCompleted)
                    }
                    onProgress?(1)
                }
                let config = WhisperKitConfig(
                    model: model,
                    modelFolder: folder.path,
                    verbose: false,
                    logLevel: .error,
                    prewarm: false,
                    load: false,
                    download: false
                )
                let kit = try await WhisperKit(config)
                publishPreparationStage(.optimizing, for: model)
                try await kit.prewarmModels()
                publishPreparationStage(.loading, for: model)
                try await kit.loadModels()
                self.whisperKit = kit
                self.parakeet = nil
            }
        }
        loadTask = task

        do {
            try await task.value
            guard generation == loadGeneration else { return }
            state = .ready
            loadedModel = model
            if failedModel == model {
                failedModel = nil
            }
            loadTask = nil
            loadingModel = nil
            preparationStage = nil
            Log.asr.notice("Transcription model ready: \(model, privacy: .public)")
        } catch {
            guard generation == loadGeneration else { throw error }
            loadTask = nil
            loadingModel = nil
            preparationStage = nil
            failedModel = model
            if let loadedModel, hasLoadedModel(loadedModel) {
                // The switch failed but the earlier model is untouched, so recognition keeps working.
                state = .ready
            } else {
                state = .failed(error.localizedDescription)
                loadedModel = nil
            }
            Log.asr.error("Transcription model failed to load: \(error, privacy: .public)")
            throw error
        }
    }

    static func initialPreparationStage(for model: String) -> ModelPreparationStage {
        model == AppSettings.parakeetModelID ? .loading : .optimizing
    }

    private func publishPreparationStage(_ stage: ModelPreparationStage, for model: String) {
        guard loadingModel == model else { return }
        preparationStage = stage
        for observer in preparationObservers.values where observer.model == model {
            observer.callback(stage)
        }
    }

    /// - Parameter language: ISO code, or `nil` to let Whisper detect it per chunk.
    func transcribe(_ samples: [Float], language: String?, model: String) async -> String? {
        await acquireTranscriptionSlot()
        defer { releaseTranscriptionSlot() }
        guard !Task.isCancelled else { return nil }

        // Audio starts flowing before the model finishes loading. Prepare the model captured by the
        // recording rather than using whichever backend happens to be resident at this instant.
        if loadedModel != model || !hasLoadedModel(model) {
            guard failedModel != model else { return nil }
            do {
                try await prepare(model: model)
            } catch {
                return nil
            }
        }
        guard loadedModel == model, hasLoadedModel(model) else { return nil }

        let text: String
        if let parakeet {
            var decoderState = TdtDecoderState.make()
            let languageHint: Language?
            switch language {
            case "ru": languageHint = .russian
            case "en": languageHint = .english
            default: languageHint = nil
            }
            guard let result = try? await parakeet.transcribe(
                samples,
                decoderState: &decoderState,
                language: languageHint
            ) else { return nil }
            text = result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        } else if let whisperKit {
            let options = DecodingOptions(
                task: .transcribe,
                language: language,
                temperature: 0,
                detectLanguage: language == nil,
                skipSpecialTokens: true,
                withoutTimestamps: true,
                compressionRatioThreshold: 2.4,
                logProbThreshold: -1.0,
                noSpeechThreshold: 0.6
            )

            let results = await whisperKit.transcribe(audioArrays: [samples], decodeOptions: options)
            guard let segments = results.first ?? nil else { return nil }
            text = segments
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return nil
        }

        guard !text.isEmpty else { return nil }
        guard !Self.isHallucination(text) else {
            // Transcript content is user data — never widen this to `.public`.
            Log.asr.debug("Dropped hallucination: \(text, privacy: .private)")
            return nil
        }

        return text
    }

    private func hasLoadedModel(_ model: String?) -> Bool {
        if model == AppSettings.parakeetModelID {
            return parakeet != nil
        }
        return whisperKit != nil
    }

    private func acquireTranscriptionSlot() async {
        if !transcriptionInProgress {
            transcriptionInProgress = true
            return
        }

        await withCheckedContinuation { continuation in
            transcriptionWaiters.append(continuation)
        }
    }

    private func releaseTranscriptionSlot() {
        guard !transcriptionWaiters.isEmpty else {
            transcriptionInProgress = false
            return
        }
        transcriptionWaiters.removeFirst().resume()
    }
}
