import Foundation

@MainActor
final class AppSettings: ObservableObject {
    enum ICloudSyncLimit: Int, CaseIterable, Identifiable {
        case disabled = 0
        case ten = 10
        case thirty = 30
        case fifty = 50
        case unlimited = -1

        var id: Int { rawValue }

        var displayName: String {
            switch self {
            case .disabled: return "Off"
            case .ten: return "Last 10 meetings"
            case .thirty: return "Last 30 meetings"
            case .fifty: return "Last 50 meetings"
            case .unlimited: return "Unlimited"
            }
        }

        var maximumMeetingCount: Int? {
            switch self {
            case .disabled: return 0
            case .ten, .thirty, .fifty: return rawValue
            case .unlimited: return nil
            }
        }
    }

    enum Language: String, CaseIterable, Identifiable {
        case auto
        case russian = "ru"
        case english = "en"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .auto: return "Detect automatically"
            case .russian: return "Russian"
            case .english: return "English"
            }
        }

        /// `nil` asks Whisper to detect the language of every chunk on its own.
        var whisperCode: String? { self == .auto ? nil : rawValue }
    }

    nonisolated static let parakeetModelID = "parakeet-tdt-0.6b-v3"

    /// Model identifiers understood by the corresponding transcription backend.
    static let availableModels: [(id: String, name: String)] = [
        ("openai_whisper-large-v3-v20240930_turbo", "Whisper large-v3 turbo — accurate, ~1.5 GB"),
        (parakeetModelID, "Parakeet TDT v3 — fast, multilingual, ~600 MB")
    ]
    static let minimumRecordingDurations = [5, 10, 30, 60, 300]

    @Published var autoDetectionEnabled: Bool { didSet { defaults.set(autoDetectionEnabled, forKey: Keys.autoDetection) } }
    @Published var liveTranscriptEnabled: Bool { didSet { defaults.set(liveTranscriptEnabled, forKey: Keys.liveTranscript) } }
    @Published var realtimeTranscriptEnabled: Bool {
        didSet { defaults.set(realtimeTranscriptEnabled, forKey: Keys.realtimeTranscript) }
    }
    @Published var transcriptDeduplicationEnabled: Bool {
        didSet { defaults.set(transcriptDeduplicationEnabled, forKey: Keys.transcriptDeduplication) }
    }
    @Published var echoGateEnabled: Bool { didSet { defaults.set(echoGateEnabled, forKey: Keys.echoGate) } }
    @Published var showPanelOnStart: Bool { didSet { defaults.set(showPanelOnStart, forKey: Keys.showPanel) } }
    @Published var minimumRecordingDuration: Int {
        didSet { defaults.set(minimumRecordingDuration, forKey: Keys.minimumRecordingDuration) }
    }
    @Published var iCloudSyncLimit: ICloudSyncLimit {
        didSet { defaults.set(iCloudSyncLimit.rawValue, forKey: Keys.iCloudSyncLimit) }
    }
    @Published private(set) var iCloudSyncFolderURL: URL?
    @Published var model: String { didSet { defaults.set(model, forKey: Keys.model) } }
    @Published var language: Language { didSet { defaults.set(language.rawValue, forKey: Keys.language) } }

    private let defaults: UserDefaults

    private enum Keys {
        static let autoDetection = "autoDetectionEnabled"
        static let liveTranscript = "liveTranscriptEnabled"
        static let realtimeTranscript = "realtimeTranscriptEnabled"
        static let transcriptDeduplication = "transcriptDeduplicationEnabled"
        static let echoGate = "echoGateEnabled"
        static let showPanel = "showPanelOnStart"
        static let minimumRecordingDuration = "minimumRecordingDuration"
        static let iCloudSyncLimit = "iCloudSyncLimit"
        static let iCloudSyncFolderBookmark = "iCloudSyncFolderBookmark"
        static let model = "whisperModel"
        static let language = "transcriptionLanguage"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.autoDetection: true,
            Keys.liveTranscript: true,
            Keys.realtimeTranscript: false,
            Keys.transcriptDeduplication: true,
            Keys.echoGate: true,
            Keys.showPanel: true,
            Keys.minimumRecordingDuration: 10,
            Keys.iCloudSyncLimit: ICloudSyncLimit.disabled.rawValue,
            Keys.model: AppSettings.availableModels[0].id,
            Keys.language: Language.auto.rawValue
        ])

        autoDetectionEnabled = defaults.bool(forKey: Keys.autoDetection)
        liveTranscriptEnabled = defaults.bool(forKey: Keys.liveTranscript)
        realtimeTranscriptEnabled = defaults.bool(forKey: Keys.realtimeTranscript)
        transcriptDeduplicationEnabled = defaults.bool(forKey: Keys.transcriptDeduplication)
        echoGateEnabled = defaults.bool(forKey: Keys.echoGate)
        showPanelOnStart = defaults.bool(forKey: Keys.showPanel)
        let storedMinimumDuration = defaults.integer(forKey: Keys.minimumRecordingDuration)
        let minimumDuration = Self.minimumRecordingDurations.contains(storedMinimumDuration)
            ? storedMinimumDuration
            : 10
        minimumRecordingDuration = minimumDuration
        defaults.set(minimumDuration, forKey: Keys.minimumRecordingDuration)
        let storedICloudSyncLimit = defaults.integer(forKey: Keys.iCloudSyncLimit)
        let selectedICloudSyncLimit = ICloudSyncLimit(rawValue: storedICloudSyncLimit) ?? .disabled
        iCloudSyncLimit = selectedICloudSyncLimit
        defaults.set(selectedICloudSyncLimit.rawValue, forKey: Keys.iCloudSyncLimit)
        let storedModel = defaults.string(forKey: Keys.model)
        let selectedModel = storedModel.flatMap { model in
            Self.availableModels.contains { $0.id == model } ? model : nil
        } ?? Self.availableModels[0].id
        model = selectedModel
        defaults.set(selectedModel, forKey: Keys.model)
        language = Language(rawValue: defaults.string(forKey: Keys.language) ?? "auto") ?? .auto

        let storedBookmark = defaults.data(forKey: Keys.iCloudSyncFolderBookmark)
        var isStale = false
        iCloudSyncFolderURL = storedBookmark.flatMap { bookmark in
            try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        }
        if isStale, let iCloudSyncFolderURL,
           let refreshedBookmark = try? iCloudSyncFolderURL.bookmarkData() {
            defaults.set(refreshedBookmark, forKey: Keys.iCloudSyncFolderBookmark)
        }
    }

    func setICloudSyncFolderURL(_ url: URL?) throws {
        guard let url else {
            iCloudSyncFolderURL = nil
            defaults.removeObject(forKey: Keys.iCloudSyncFolderBookmark)
            return
        }

        let bookmark = try url.bookmarkData()
        defaults.set(bookmark, forKey: Keys.iCloudSyncFolderBookmark)
        iCloudSyncFolderURL = url
    }
}
