import XCTest
@testable import MeetingsHelper

final class DetectedMeetingTests: XCTestCase {
    func testManualRecordingCapturesAllSystemAudio() {
        let meeting = detectedMeeting(kind: .manual, audioPrefixes: [])

        XCTAssertTrue(meeting.capturesAllSystemAudio)
        XCTAssertEqual(meeting.audioSourceDisplayName, "All system audio")
    }

    func testAutomaticRecordingKeepsApplicationScopedAudio() {
        let zoom = detectedMeeting(kind: .zoom, audioPrefixes: MeetingApp.zoom.audioBundleIDPrefixes)
        let chrome = detectedMeeting(kind: .googleMeet, audioPrefixes: MeetingApp.chrome.audioBundleIDPrefixes)

        XCTAssertFalse(zoom.capturesAllSystemAudio)
        XCTAssertEqual(zoom.audioSourceDisplayName, "Zoom")
        XCTAssertFalse(chrome.capturesAllSystemAudio)
        XCTAssertEqual(chrome.audioSourceDisplayName, "Google Chrome")
    }

    private func detectedMeeting(
        kind: DetectedMeeting.Kind,
        audioPrefixes: [String]
    ) -> DetectedMeeting {
        DetectedMeeting(
            kind: kind,
            title: "Test meeting",
            audioPrefixes: audioPrefixes,
            detectedAt: Date()
        )
    }
}
