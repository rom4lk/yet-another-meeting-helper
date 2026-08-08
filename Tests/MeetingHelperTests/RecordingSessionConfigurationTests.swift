import XCTest
@testable import MeetingHelper

@MainActor
final class RecordingSessionConfigurationTests: XCTestCase {
    func testModelIsCapturedWhenTheRecordingSessionIsCreated() {
        let suiteName = "RecordingSessionConfigurationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let initialModel = AppSettings.availableModels[0].id
        let replacementModel = AppSettings.availableModels[1].id
        settings.liveTranscriptEnabled = true
        settings.model = initialModel

        let session = RecordingSession(
            detected: DetectedMeeting(
                kind: .manual,
                title: "Model capture test",
                audioPrefixes: [],
                detectedAt: Date()
            ),
            settings: settings,
            engine: TranscriptionEngine()
        )
        settings.model = replacementModel

        XCTAssertEqual(session.transcriptionModel, initialModel)
    }
}
