import Foundation

@MainActor
final class AppSettings: ObservableObject {
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

    /// Model identifiers understood by WhisperKit's model repository.
    static let availableModels: [(id: String, name: String)] = [
        ("openai_whisper-large-v3-v20240930_turbo", "large-v3 turbo — accurate, ~1.5 GB"),
        ("openai_whisper-large-v3-v20240930_626MB", "large-v3 compressed — a compromise, ~630 MB"),
        ("openai_whisper-small", "small — fast, ~470 MB"),
        ("openai_whisper-base", "base — draft quality, ~150 MB")
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
        model = defaults.string(forKey: Keys.model) ?? AppSettings.availableModels[0].id
        language = Language(rawValue: defaults.string(forKey: Keys.language) ?? "auto") ?? .auto
    }
}
