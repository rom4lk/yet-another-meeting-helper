# The echo gate: what it is and how its thresholds were measured

Measurements from 2026-08-01, on the same machine as
[acoustic-echo-cancellation.md](acoustic-echo-cancellation.md). Read that one first: it records
why the macOS voice-processing unit was removed instead of fixed, and this gate is what replaced
it.

## What the gate does

Nothing to the audio. `mic.wav` still contains the speaker leakage, and so does the mixdown. The
gate only decides whether a microphone utterance is worth sending to Whisper
([EchoGate.swift](../Sources/MeetingHelper/Audio/EchoGate.swift),
[EchoReference.swift](../Sources/MeetingHelper/Audio/EchoReference.swift), called from
`SourceTranscriber.closeUtterance`).

It works on the per-100 ms loudness envelope of both tracks, which
[AudioTrackWriter](../Sources/MeetingHelper/Audio/AudioTrackWriter.swift) already aligns to a
shared timeline. Echo repeats the shape of the system envelope, delayed and attenuated, so an
utterance is dropped when **both** hold at the same lag:

| | |
|---|---|
| Envelope correlation (Pearson, best lag in 0…500 ms) | ≥ 0.80 |
| Microphone level relative to the reference | ≤ −18 dB |
| Reference level in the window | ≥ −50 dB |
| Window length | ≥ 5 frames (0.5 s) |

Requiring both conditions is the whole design. Correlation alone does not separate the classes —
in the measurements below, real speech reached 0.70 and the quietest echo sat at 0.72. Level alone
is setup-dependent. Together they leave a 4.7 dB margin on the level axis for every labelled
sample.

Everything short of a confident verdict passes: no reference, a window older than the 60 s buffer,
coverage that has not arrived within 0.5 s. `TranscriptDeduplicator` is the second net, and
dropping real speech is the worse failure.

The gate is on by default and can be turned off in Settings. Off means `RecordingSession` never
builds an `EchoReference`, so the system track is not buffered and no utterance waits for it —
the 0.5 s coverage wait is the gate's only latency cost.

## Ground truth

Recordings under `~/Library/Application Support/MeetingHelper/Meetings`, chosen because their
labels do not depend on the thing being measured:

| Recording | Why it is usable |
|---|---|
| `BA222CB1`, `E23417BF` | Titled "I said nothing" — every microphone utterance over audible playback is echo by construction. 35 windows. |
| `ECCF608C` | Voice chat: turn-taking, so speech and playback are separable. 3 windows are speech over audible playback. |
| `36C43044` | 15-minute personal call over speakers, 197 windows. The realistic mix. |
| `EB8F3D5C` | The 27 s sample from the AEC notes, 5 known duplicate pairs. **Recorded through VPIO**, whose makeup gain pushed the microphone up ~19 dB, so its level differences (≈ 0 dB) are not representative of the raw path. Kept as a correlation check only. |

## What the numbers looked like

Echo and speech separate cleanly on level, barely at all on correlation:

| | correlation | mic − reference |
|---|---|---|
| Echo (`ECCF608C`, `BA222CB1`, `E23417BF`) | 0.72 … 0.98 | −19 … −28 dB |
| Speech over audible playback (`ECCF608C`) | 0.36 … 0.70 | −11 … −13 dB |
| Speech with the system silent | −0.3 … 0.34 | reference below −100 dB |

Threshold sweep against the labelled sets — 35 windows that must be flagged, 12 that must not:

| correlation | level | echo caught | speech lost |
|---|---|---|---|
| 0.70 | −16 dB | 35/35 | 0/12 |
| 0.75 | −18 dB | 34/35 | 0/12 |
| **0.80** | **−18 dB** | **34/35** | **0/12** |
| 0.85 | −18 dB | 33/35 | 0/12 |

0.80 / −18 dB was picked over the more permissive rows because nothing above it costs recall worth
having, and the extra distance from the speech cluster is worth more than the one missed echo.

## Replaying the shipping code

The thresholds were tuned on a standalone probe, then verified by running the real
`SourceTranscriber` + `EchoReference` + `EchoGate` over the recordings:

| Recording | Utterances | Dropped |
|---|---|---|
| `BA222CB1` (said nothing) | 23 | 21 |
| `E23417BF` (said nothing) | 13 | 12 — the 13th is speech before the video started |
| `ECCF608C` (voice chat) | 22 | 12 |
| `36C43044` (personal call) | 197 | 72 |
| `EB8F3D5C` (VPIO-era) | 5 | 0 — level difference ≈ 0 dB, see above |

On the personal call, of the 72 dropped windows 37 were also catchable by text comparison and
**34 were not** — the two tracks had produced different words for the same speech. Those 34 are
duplicates that no amount of transcript-level work would have removed. Of the 125 kept windows,
63 are text-confirmed echo that `TranscriptDeduplicator` still removes downstream, and 33 carry
the level signature of real speech. Not one dropped window had a level difference above −18.7 dB.

## Re-running it

The replay is a throwaway test, not part of the suite — it depends on recordings that are not in
the repository. Drop this into `Tests/MeetingHelperTests`, run
`xcodebuild ... test -only-testing:MeetingHelperTests/EchoGateFixtureTests`, then delete it and
`xcodegen generate` again.

Feeding the two tracks in step matters. Appending a whole `system.wav` up front makes every window
older than the reference's 60 s buffer fail open, which silently looks like a gate that does
nothing — on the 15-minute call that showed 2 drops instead of 72.

```swift
import AVFoundation
import XCTest
@testable import MeetingHelper

final class EchoGateFixtureTests: XCTestCase {
    final class Counter {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private func load(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    /// Replays both tracks the way they arrive during a recording: the reference stays a couple
    /// of seconds ahead of the microphone and never outruns its 60 s buffer.
    private func count(mic: [Float], system: [Float], reference: EchoReference?) async -> Int {
        let counter = Counter()
        let transcriber = SourceTranscriber(
            source: .me,
            language: "en",
            echoReference: reference,
            transcribe: { _, _ in "line" },
            onLine: { _ in counter.increment() }
        )

        let chunk = Int(AudioTrackWriter.sampleRate)
        let lead = 2 * chunk
        var position = 0
        var referenceFilled = 0
        while position < mic.count {
            let target = min(position + chunk + lead, system.count)
            if let reference, referenceFilled < target {
                reference.append(Array(system[referenceFilled..<target]))
                referenceFilled = target
            }
            transcriber.feed(Array(mic[position..<min(position + chunk, mic.count)]))
            position += chunk
            try? await Task.sleep(nanoseconds: 3_000_000)
        }

        await transcriber.finish(waitForTranscription: true)
        return counter.value
    }

    func testGateOnRecordedMeetings() async throws {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MeetingHelper/Meetings")
        let directories = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []

        for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let mic = load(directory.appendingPathComponent("mic.wav")),
                  let system = load(directory.appendingPathComponent("system.wav")),
                  mic.count > 16_000, system.count > 16_000
            else { continue }

            let withoutGate = await count(mic: mic, system: system, reference: nil)
            let withGate = await count(mic: mic, system: system, reference: EchoReference())
            print("FIXTURE \(directory.lastPathComponent.prefix(8)): utterances=\(withoutGate) dropped=\(withoutGate - withGate)")
        }
    }
}
```

## Caveats

- **The thresholds are calibrated on one machine and one speaker/microphone geometry.** The code is
  portable — it touches no device-specific Core Audio behaviour, unlike VPIO — but how far echo
  sits below the source depends on speaker volume, distance and the room. Re-measure before
  trusting the numbers on very different hardware.
- **Reverberation smears the envelope**, which lowers correlation. A gulped room would push echo
  towards the 0.80 boundary and the gate would quietly stop firing. It fails open, not shut.
- **Headphones need no special handling.** There is no leakage, so the level test never passes and
  the gate never fires.
- Recordings made before this change went in were captured through VPIO with its makeup gain and
  are not comparable on level.
