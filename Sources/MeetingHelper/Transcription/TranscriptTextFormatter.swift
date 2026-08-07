import Foundation

enum TranscriptTextFormatter {
    @MainActor
    static func string(from lines: [TranscriptLine], transcriptionModel: String?) -> String {
        let transcript = lines
            .map { "[\($0.timestamp)] \($0.source.title): \($0.text)" }
            .joined(separator: "\n")

        guard let transcriptionModel else { return transcript }

        let modelName = AppSettings.displayName(forModel: transcriptionModel)
        return "Transcription model: \(modelName)\n\n\(transcript)"
    }
}
