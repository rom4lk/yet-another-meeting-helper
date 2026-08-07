import XCTest
@testable import MeetingHelper

final class ModelPreparationStageTests: XCTestCase {
    func testWhisperStartsWithDeviceOptimization() {
        for model in ["openai_whisper-large-v3-v20240930_turbo", "openai_whisper-large-v3"] {
            XCTAssertEqual(TranscriptionEngine.initialPreparationStage(for: model), .optimizing)
        }
    }

    func testParakeetStartsWithLoading() {
        XCTAssertEqual(
            TranscriptionEngine.initialPreparationStage(for: AppSettings.parakeetModelID),
            .loading
        )
    }

    func testPreparationStagesExplainExpectedDuration() {
        XCTAssertEqual(ModelPreparationStage.optimizing.statusText, "Optimizing for Apple Neural Engine…")
        XCTAssertTrue(ModelPreparationStage.optimizing.detailText.contains("10 minutes or more"))
        XCTAssertEqual(ModelPreparationStage.loading.statusText, "Loading model into memory…")
        XCTAssertTrue(ModelPreparationStage.loading.detailText.contains("a few seconds"))
    }
}
