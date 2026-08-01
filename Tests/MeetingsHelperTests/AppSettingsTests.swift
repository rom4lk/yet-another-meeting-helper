import XCTest
@testable import MeetingsHelper

@MainActor
final class AppSettingsTests: XCTestCase {
    func testAudioCleanupOptionsPersistIndependently() {
        for echoCancellationEnabled in [false, true] {
            for deduplicationEnabled in [false, true] {
                let suiteName = "AppSettingsTests.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suiteName)!
                defer { defaults.removePersistentDomain(forName: suiteName) }

                let settings = AppSettings(defaults: defaults)
                settings.acousticEchoCancellationEnabled = echoCancellationEnabled
                settings.transcriptDeduplicationEnabled = deduplicationEnabled

                let restored = AppSettings(defaults: defaults)
                XCTAssertEqual(restored.acousticEchoCancellationEnabled, echoCancellationEnabled)
                XCTAssertEqual(restored.transcriptDeduplicationEnabled, deduplicationEnabled)
            }
        }
    }

    func testAudioCleanupOptionsDefaultToEnabled() {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)

        XCTAssertTrue(settings.acousticEchoCancellationEnabled)
        XCTAssertTrue(settings.transcriptDeduplicationEnabled)
    }
}
