import AudioToolbox
import XCTest
@testable import MeetingHelper

final class SystemAudioTapTests: XCTestCase {
    func testAggregateContainsOnlyTheProcessTap() throws {
        let tapUUID = UUID()
        let description = SystemAudioTap.aggregateDescription(tapUUID: tapUUID)

        XCTAssertNil(description[kAudioAggregateDeviceMainSubDeviceKey])
        XCTAssertNil(description[kAudioAggregateDeviceSubDeviceListKey])

        let taps = try XCTUnwrap(
            description[kAudioAggregateDeviceTapListKey] as? [[String: Any]]
        )
        XCTAssertEqual(taps.count, 1)
        XCTAssertEqual(taps[0][kAudioSubTapUIDKey] as? String, tapUUID.uuidString)
    }
}
