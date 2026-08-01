import Foundation

enum TranscriptSource: String, Codable, CaseIterable {
    /// Captured from the microphone.
    case me
    /// Captured from the meeting app's audio output.
    case others

    var title: String {
        switch self {
        case .me: return "Me"
        case .others: return "Others"
        }
    }
}

struct TranscriptLine: Identifiable, Codable, Hashable {
    let id: UUID
    let source: TranscriptSource
    /// Seconds from the start of the recording.
    let offset: TimeInterval
    let text: String

    init(id: UUID = UUID(), source: TranscriptSource, offset: TimeInterval, text: String) {
        self.id = id
        self.source = source
        self.offset = offset
        self.text = text
    }

    var timestamp: String {
        let total = Int(offset)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
