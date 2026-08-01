import XCTest
@testable import MeetingHelper

@MainActor
final class AppSettingsTests: XCTestCase {
    func testParakeetMultilingualModelIsAvailable() {
        XCTAssertTrue(AppSettings.availableModels.contains { model in
            model.id == AppSettings.parakeetModelID
        })
    }

    func testOnlyTurboAndParakeetModelsAreAvailable() {
        XCTAssertEqual(
            AppSettings.availableModels.map(\.id),
            ["openai_whisper-large-v3-v20240930_turbo", AppSettings.parakeetModelID]
        )
    }

    func testRemovedModelFallsBackToTurbo() {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("openai_whisper-small", forKey: "whisperModel")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.model, "openai_whisper-large-v3-v20240930_turbo")
    }

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

    func testICloudSyncLimitOptions() {
        XCTAssertEqual(
            AppSettings.ICloudSyncLimit.allCases,
            [.disabled, .ten, .thirty, .fifty, .unlimited]
        )
        XCTAssertEqual(
            AppSettings.ICloudSyncLimit.allCases.map(\.maximumMeetingCount),
            [0, 10, 30, 50, nil]
        )
    }

    func testICloudSyncDefaultsToDisabled() {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.iCloudSyncLimit, .disabled)
    }

    func testICloudSyncLimitPersists() {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.iCloudSyncLimit = .fifty

        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.iCloudSyncLimit, .fifty)
    }

    func testUnknownICloudSyncLimitFallsBackToDisabled() {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(20, forKey: "iCloudSyncLimit")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.iCloudSyncLimit, .disabled)
    }

    func testICloudSyncFolderBookmarkPersists() throws {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let settings = AppSettings(defaults: defaults)
        try settings.setICloudSyncFolderURL(folderURL)

        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(
            restored.iCloudSyncFolderURL?.standardizedFileURL,
            folderURL.standardizedFileURL
        )
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
