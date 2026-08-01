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

    @Published var autoDetectionEnabled: Bool { didSet { defaults.set(autoDetectionEnabled, forKey: Keys.autoDetection) } }
    @Published var liveTranscriptEnabled: Bool { didSet { defaults.set(liveTranscriptEnabled, forKey: Keys.liveTranscript) } }
    @Published var showPanelOnStart: Bool { didSet { defaults.set(showPanelOnStart, forKey: Keys.showPanel) } }
    @Published var model: String { didSet { defaults.set(model, forKey: Keys.model) } }
    @Published var language: Language { didSet { defaults.set(language.rawValue, forKey: Keys.language) } }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let autoDetection = "autoDetectionEnabled"
        static let liveTranscript = "liveTranscriptEnabled"
        static let showPanel = "showPanelOnStart"
        static let model = "whisperModel"
        static let language = "transcriptionLanguage"
    }

    init() {
        defaults.register(defaults: [
            Keys.autoDetection: true,
            Keys.liveTranscript: true,
            Keys.showPanel: true,
            Keys.model: AppSettings.availableModels[0].id,
            Keys.language: Language.auto.rawValue
        ])

        autoDetectionEnabled = defaults.bool(forKey: Keys.autoDetection)
        liveTranscriptEnabled = defaults.bool(forKey: Keys.liveTranscript)
        showPanelOnStart = defaults.bool(forKey: Keys.showPanel)
        model = defaults.string(forKey: Keys.model) ?? AppSettings.availableModels[0].id
        language = Language(rawValue: defaults.string(forKey: Keys.language) ?? "auto") ?? .auto
    }
}
