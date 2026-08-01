import XCTest
@testable import MeetingsHelper

final class EchoGateTests: XCTestCase {
    /// A speech-shaped loudness envelope, one value per 100 ms frame.
    private let playback: [Float] = [0.02, 0.05, 0.10, 0.14, 0.18, 0.20, 0.16, 0.11, 0.06, 0.03]

    /// Places `envelope` in a reference window at the given acoustic delay, padding the rest.
    private func reference(_ envelope: [Float], lag: Int, padding: Float = 0.01) -> [Float] {
        var window = [Float](repeating: padding, count: envelope.count + EchoGate.maximumLagFrames)
        let start = EchoGate.maximumLagFrames - lag
        window.replaceSubrange(start..<(start + envelope.count), with: envelope)
        return window
    }

    func testAttenuatedCopyOfThePlaybackIsEcho() {
        let microphone = playback.map { $0 * 0.1 }

        XCTAssertTrue(EchoGate.isEcho(microphone: microphone, reference: reference(playback, lag: 0)))
    }

    func testEchoIsFoundAtEveryDelayWithinTheSearchRange() {
        let microphone = playback.map { $0 * 0.1 }

        for lag in 0...EchoGate.maximumLagFrames {
            XCTAssertTrue(
                EchoGate.isEcho(microphone: microphone, reference: reference(playback, lag: lag)),
                "Echo delayed by \(lag) frames was not recognized"
            )
        }
    }

    func testSpeechOverPlaybackIsKept() {
        // Same shape as the playback, but the speaker is at the microphone: only 6 dB down.
        let microphone = playback.map { $0 * 0.5 }

        XCTAssertFalse(EchoGate.isEcho(microphone: microphone, reference: reference(playback, lag: 0)))
    }

    func testQuietButUncorrelatedSpeechIsKept() {
        // Far quieter than the playback, yet its own shape — someone talking while a video runs.
        let microphone: [Float] = [0.020, 0.016, 0.003, 0.018, 0.004, 0.019, 0.005, 0.017, 0.002, 0.015]

        XCTAssertLessThan(EchoGate.correlation(microphone, playback), EchoGate.minimumCorrelation)
        XCTAssertFalse(EchoGate.isEcho(microphone: microphone, reference: reference(playback, lag: 0)))
    }

    func testSilentReferenceIsKept() {
        let microphone = playback.map { $0 * 0.1 }
        let silence = [Float](repeating: 0, count: playback.count + EchoGate.maximumLagFrames)

        XCTAssertFalse(EchoGate.isEcho(microphone: microphone, reference: silence))
    }

    func testTooShortAWindowIsKept() {
        let short = Array(playback.prefix(EchoGate.minimumFrames - 1))
        let microphone = short.map { $0 * 0.1 }

        XCTAssertFalse(EchoGate.isEcho(microphone: microphone, reference: reference(short, lag: 0)))
    }

    func testReferenceOfTheWrongLengthIsKept() {
        let microphone = playback.map { $0 * 0.1 }

        XCTAssertFalse(EchoGate.isEcho(microphone: microphone, reference: playback))
    }
}
