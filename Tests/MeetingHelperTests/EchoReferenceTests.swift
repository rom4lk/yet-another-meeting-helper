import XCTest
@testable import MeetingHelper

final class EchoReferenceTests: XCTestCase {
    private func frames(_ amplitudes: [Float]) -> [Float] {
        amplitudes.flatMap { [Float](repeating: $0, count: EchoReference.frameSize) }
    }

    func testEnvelopeFollowsTheTimeline() {
        let reference = EchoReference()
        reference.append(frames([0.1, 0.2, 0.3, 0.4, 0.5]))

        XCTAssertEqual(reference.coveredUntil, 0.5, accuracy: 0.001)

        let envelope = reference.envelope(startingAt: 0.2, frameCount: 2)
        XCTAssertEqual(envelope?.count, 2)
        XCTAssertEqual(envelope?[0] ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(envelope?[1] ?? 0, 0.4, accuracy: 0.001)
    }

    func testSamplesArriveInAnyChunkSize() {
        let reference = EchoReference()
        let samples = frames([0.1, 0.2, 0.3])

        // Split across chunk boundaries that do not line up with frames.
        for chunk in stride(from: 0, to: samples.count, by: 700) {
            reference.append(Array(samples[chunk..<min(chunk + 700, samples.count)]))
        }

        XCTAssertEqual(reference.coveredUntil, 0.3, accuracy: 0.001)
        XCTAssertEqual(reference.envelope(startingAt: 0.1, frameCount: 1)?.first ?? 0, 0.2, accuracy: 0.001)
    }

    func testIncompleteFrameDoesNotAdvanceCoverage() {
        let reference = EchoReference()
        reference.append([Float](repeating: 0.1, count: EchoReference.frameSize - 1))

        XCTAssertEqual(reference.coveredUntil, 0)
        XCTAssertFalse(reference.hasData)
        XCTAssertNil(reference.envelope(startingAt: 0, frameCount: 1))
    }

    func testWindowBeyondCoverageIsUnavailable() {
        let reference = EchoReference()
        reference.append(frames([0.1, 0.2]))

        XCTAssertTrue(reference.hasData)
        XCTAssertNil(reference.envelope(startingAt: 0.1, frameCount: 5))
        XCTAssertNil(reference.envelope(startingAt: -0.1, frameCount: 1))
    }

    func testFramesOlderThanTheBufferAreUnavailable() {
        let reference = EchoReference()
        for _ in 0..<700 {
            reference.append([Float](repeating: 0.1, count: EchoReference.frameSize))
        }

        XCTAssertEqual(reference.coveredUntil, 70, accuracy: 0.001)
        XCTAssertNil(reference.envelope(startingAt: 0, frameCount: 1))
        XCTAssertEqual(reference.envelope(startingAt: 69, frameCount: 1)?.first ?? 0, 0.1, accuracy: 0.001)
    }
}
