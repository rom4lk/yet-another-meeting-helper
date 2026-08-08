import AppKit
import XCTest
@testable import MeetingHelper

@MainActor
final class ApplicationTerminationHandlerTests: XCTestCase {
    private final class Controller: ApplicationTerminationControlling {
        var isRecording = false
        var isStopping = false
        private(set) var stopCallCount = 0
        private(set) var startsPendingMeeting: Bool?
        private(set) var stopCompletion: (() -> Void)?

        func requestStop(startsPendingMeeting: Bool, completion: @escaping () -> Void) {
            stopCallCount += 1
            self.startsPendingMeeting = startsPendingMeeting
            stopCompletion = completion
        }
    }

    func testActiveRecordingDelaysTerminationUntilRecordingStops() {
        let controller = Controller()
        controller.isRecording = true
        var didReplyAfterStopping = false

        let reply = ApplicationTerminationHandler.reply(for: controller) {
            didReplyAfterStopping = true
        }

        XCTAssertEqual(reply, .terminateLater)
        XCTAssertEqual(controller.stopCallCount, 1)
        XCTAssertEqual(controller.startsPendingMeeting, false)
        XCTAssertFalse(didReplyAfterStopping)

        controller.stopCompletion?()

        XCTAssertTrue(didReplyAfterStopping)
    }

    func testTerminationWhileAlreadyStoppingWaitsForTheSameStop() {
        let controller = Controller()
        controller.isStopping = true

        let reply = ApplicationTerminationHandler.reply(for: controller) {}

        XCTAssertEqual(reply, .terminateLater)
        XCTAssertEqual(controller.stopCallCount, 1)
    }

    func testIdleApplicationTerminatesImmediately() {
        let controller = Controller()

        let reply = ApplicationTerminationHandler.reply(for: controller) {
            XCTFail("Idle termination should not wait for recording")
        }

        XCTAssertEqual(reply, .terminateNow)
        XCTAssertEqual(controller.stopCallCount, 0)
    }
}
