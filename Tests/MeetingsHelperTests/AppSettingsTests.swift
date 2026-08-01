import XCTest
@testable import MeetingsHelper

@MainActor
final class AppSettingsTests: XCTestCase {
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
