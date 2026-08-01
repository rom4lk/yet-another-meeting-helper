import Foundation
import WhisperKit

/// Owns the WhisperKit pipeline. An actor because the model must not be entered concurrently —
/// both tracks funnel their chunks through here and get serialised for free.
actor TranscriptionEngine {
    enum State: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    static let repo = "argmaxinc/whisperkit-coreml"

    private static let downloadBase: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MeetingsHelper", directoryHint: .isDirectory)
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
    private var loadedModel: String?
    private var loadTask: Task<Void, Error>?
    private var loadingModel: String?
    private var loadGeneration = 0

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

    /// Whether the model files are already in the Hugging Face cache, so a download would be a
    /// no-op. Checks the three CoreML bundles `loadModels` requires, because an interrupted
    /// download leaves the folder in place with only part of them.
    static func isDownloaded(_ model: String) -> Bool {
        downloadedModelFolder(model) != nil
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
    /// - Parameter onProgress: fraction of the download, `1` once the bytes are in and the model
    ///   is being loaded into memory. Never called for an already cached model.
    func prepare(model: String, onProgress: (@Sendable (Double) -> Void)? = nil) async throws {
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
            if activeModel == model, whisperKit != nil { return }
        }
        if case .ready = state, whisperKit != nil, loadedModel == model { return }

        state = .loading
        loadingModel = model
        loadGeneration += 1
        let generation = loadGeneration
        let task = Task<Void, Error> {
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
                prewarm: true,
                load: true,
                download: false
            )
            let kit = try await WhisperKit(config)
            self.whisperKit = kit
        }
        loadTask = task

        do {
            try await task.value
            guard generation == loadGeneration else { return }
            state = .ready
            loadedModel = model
            loadTask = nil
            loadingModel = nil
            Log.asr.notice("WhisperKit ready: \(model, privacy: .public)")
        } catch {
            guard generation == loadGeneration else { throw error }
            state = .failed(error.localizedDescription)
            loadedModel = nil
            loadTask = nil
            loadingModel = nil
            Log.asr.error("WhisperKit failed to load: \(error, privacy: .public)")
            throw error
        }
    }

    /// - Parameter language: ISO code, or `nil` to let Whisper detect it per chunk.
    func transcribe(_ samples: [Float], language: String?) async -> String? {
        // Audio starts flowing before the model finishes loading; hold the chunk instead of
        // dropping it, so the first minute of a meeting is not lost.
        if whisperKit == nil, let loadTask {
            try? await loadTask.value
        }
        guard let whisperKit else { return nil }

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

        let text = segments
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { return nil }
        guard !Self.hallucinations.contains(text.lowercased()) else {
            Log.asr.debug("Dropped hallucination: \(text, privacy: .public)")
            return nil
        }

        return text
    }
}
