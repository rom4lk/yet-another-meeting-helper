import XCTest
@testable import MeetingHelper

@MainActor
final class AppSettingsTests: XCTestCase {
    func testMinimumRecordingDurationOptions() {
        XCTAssertEqual(AppSettings.minimumRecordingDurations, [5, 10, 30, 60, 300])
    }

    func testRealtimeTranscriptOptionPersists() {
        for realtimeEnabled in [false, true] {
            let suiteName = "AppSettingsTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let settings = AppSettings(defaults: defaults)
            settings.realtimeTranscriptEnabled = realtimeEnabled

            let restored = AppSettings(defaults: defaults)
            XCTAssertEqual(restored.realtimeTranscriptEnabled, realtimeEnabled)
        }
    }

    func testRealtimeTranscriptDefaultsToDisabled() {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)

        XCTAssertFalse(settings.realtimeTranscriptEnabled)
    }

    func testMinimumRecordingDurationPersists() {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.minimumRecordingDuration = 300

        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.minimumRecordingDuration, 300)
    }

    func testMinimumRecordingDurationDefaultsToTenSeconds() {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.minimumRecordingDuration, 10)
    }

    func testDeduplicationOptionPersists() {
        for deduplicationEnabled in [false, true] {
            let suiteName = "AppSettingsTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let settings = AppSettings(defaults: defaults)
            settings.transcriptDeduplicationEnabled = deduplicationEnabled

            let restored = AppSettings(defaults: defaults)
            XCTAssertEqual(restored.transcriptDeduplicationEnabled, deduplicationEnabled)
        }
    }

    func testDeduplicationDefaultsToEnabled() {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)

        XCTAssertTrue(settings.transcriptDeduplicationEnabled)
    }

    func testEchoGateOptionPersists() {
        for gateEnabled in [false, true] {
            let suiteName = "AppSettingsTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let settings = AppSettings(defaults: defaults)
            settings.echoGateEnabled = gateEnabled

            let restored = AppSettings(defaults: defaults)
            XCTAssertEqual(restored.echoGateEnabled, gateEnabled)
        }
    }

    func testEchoGateDefaultsToEnabled() {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)

        XCTAssertTrue(settings.echoGateEnabled)
    }
}
