import XCTest
@testable import MeetingsHelper

final class TranscriptDeduplicatorTests: XCTestCase {
    func testMicDuplicateIsSkippedWhenSystemLineAlreadyExists() {
        let system = line(.others, 249, "On the left side. This has not happened for a long time.")
        let microphone = line(.me, 249.7, "On the left side. Well, this has not happened for a long time.")
        var lines = [system]

        TranscriptDeduplicator.insert(microphone, into: &lines)

        XCTAssertEqual(lines, [system])
    }

    func testSystemLineReplacesEarlierMicDuplicate() {
        let microphone = line(.me, 255, "I think I should see the doctor after all. Then she arrived.")
        let system = line(.others, 254.2, "I think I should see the doctor after all. Then she arrived...")
        var lines = [microphone]

        TranscriptDeduplicator.insert(system, into: &lines)

        XCTAssertEqual(lines, [system])
    }

    func testSystemLineReplacesContainedShortMicEchoAtSameTime() {
        let microphone = line(.me, 31, "Is there a topic you want to discuss?")
        let system = line(.others, 29.7, "Great. Is there a topic you want to discuss, or should we keep testing the sound?")
        var lines = [microphone]

        TranscriptDeduplicator.insert(system, into: &lines)

        XCTAssertEqual(lines, [system])
    }

    func testSameSourceRepetitionIsPreserved() {
        let first = line(.me, 10, "Please send the report tomorrow.")
        let second = line(.me, 11, "Please send the report tomorrow.")
        var lines = [first]

        TranscriptDeduplicator.insert(second, into: &lines)

        XCTAssertEqual(lines, [first, second])
    }

    func testShortCommonResponseIsPreserved() {
        let system = line(.others, 10, "Yes.")
        let microphone = line(.me, 10.5, "Yes.")
        var lines = [system]

        TranscriptDeduplicator.insert(microphone, into: &lines)

        XCTAssertEqual(lines, [system, microphone])
    }

    func testDistantMatchingLineIsPreserved() {
        let system = line(.others, 10, "Please send the report tomorrow.")
        let microphone = line(.me, 20, "Please send the report tomorrow.")
        var lines = [system]

        TranscriptDeduplicator.insert(microphone, into: &lines)

        XCTAssertEqual(lines, [system, microphone])
    }

    func testUnrelatedCrossSourceLinesArePreserved() {
        let system = line(.others, 10, "Please send the report tomorrow.")
        let microphone = line(.me, 10.5, "I will prepare a new presentation today.")
        var lines = [system]

        TranscriptDeduplicator.insert(microphone, into: &lines)

        XCTAssertEqual(lines, [system, microphone])
    }

    private func line(_ source: TranscriptSource, _ offset: TimeInterval, _ text: String) -> TranscriptLine {
        TranscriptLine(source: source, offset: offset, text: text)
    }
}
