import Foundation
import os

/// The loudness of the system audio track, kept on the shared recording timeline.
///
/// Speaker playback leaks into the microphone whenever the meeting is not listened to through
/// headphones, and both tracks then transcribe the same speech. `EchoGate` tells that leakage
/// apart from real speech by comparing the microphone against this envelope, so the samples
/// stored here are the reference signal — the audio as the app played it, before the room.
///
/// Written from the system track's writer callback and read from the microphone transcriber's
/// queue, hence the lock.
final class EchoReference {
    /// 100 ms at `AudioTrackWriter.sampleRate`, the same frame the transcriber's VAD uses.
    static let frameSize = 1_600
    static let frameDuration = Double(frameSize) / AudioTrackWriter.sampleRate

    /// Long enough to cover any utterance the VAD can produce, with room to spare.
    private static let capacity = 600

    private struct Storage {
        var levels: [Float] = []
        var firstFrameIndex = 0
        var framesWritten = 0
        var pending: [Float] = []
    }

    private let storage = OSAllocatedUnfairLock(initialState: Storage())

    /// How much of the timeline the reference covers, in seconds from the start of the recording.
    /// The writer pads gaps with silence, so this advances even while the meeting is quiet.
    var coveredUntil: TimeInterval {
        storage.withLock { Double($0.framesWritten) * Self.frameDuration }
    }

    /// Whether any system audio has been seen at all. False when the tap never started, which is
    /// the caller's signal that waiting for coverage is pointless.
    var hasData: Bool {
        storage.withLock { $0.framesWritten > 0 }
    }

    func append(_ samples: [Float]) {
        storage.withLock { state in
            state.pending.append(contentsOf: samples)

            while state.pending.count >= Self.frameSize {
                let frame = state.pending.prefix(Self.frameSize)
                state.pending.removeFirst(Self.frameSize)

                state.levels.append(Self.rms(frame))
                state.framesWritten += 1
                if state.levels.count > Self.capacity {
                    state.levels.removeFirst()
                    state.firstFrameIndex += 1
                }
            }
        }
    }

    /// The envelope covering `[start, start + frameCount)`, or `nil` when that span has already
    /// been dropped from the buffer or has not been written yet.
    func envelope(startingAt start: TimeInterval, frameCount: Int) -> [Float]? {
        guard start >= 0, frameCount > 0 else { return nil }
        let startFrame = Int((start / Self.frameDuration).rounded())
        let endFrame = startFrame + frameCount

        return storage.withLock { state in
            guard startFrame >= state.firstFrameIndex, endFrame <= state.framesWritten else { return nil }
            let lower = startFrame - state.firstFrameIndex
            return Array(state.levels[lower..<(lower + frameCount)])
        }
    }

    private static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}
