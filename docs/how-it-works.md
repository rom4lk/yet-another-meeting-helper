# How Meeting Helper Works

This document describes the implementation behind meeting detection, audio capture, speaker
attribution, and transcription. For installation and usage, see the [README](../README.md).

## Meeting detection

Meeting Helper combines three signals, from precise to general.

| Layer | Signal | What it covers |
|---|---|---|
| Meeting process | Presence of `us.zoom.CptHost` | Zoom, native client |
| Process audio activity | `kAudioProcessPropertyIsRunningInput` over a bundle ID family | The browser is holding the microphone |
| Window title | Accessibility API | Distinguishes Google Meet from other tabs and provides the meeting title |

Zoom spawns the `CptHost` helper process for the duration of a conference and terminates it when the
user leaves. This gives the app a precise start and end signal, unlike general microphone activity,
which also occurs during dictation and audio checks.

`CptHost` must be polled. It is an agent (`LSUIElement`), and `NSWorkspace` does not post
`didLaunchApplicationNotification` or `didTerminateApplicationNotification` for agents. They appear
in `runningApplications`, but no lifecycle notifications arrive for them. A live test confirmed that
leaving a conference produced a notification for `us.zoom.xos` but not for `us.zoom.CptHost`.

Browser meetings do not have an equivalent helper process. Meeting Helper therefore requires both
microphone activity and a window title that looks like Google Meet. Without Accessibility access,
browser meeting detection is unavailable, while Zoom detection continues to work.

## Audio capture and storage

The microphone goes through an `AVAudioEngine` tap. When the input device changes, the engine is
restarted automatically and gaps longer than one second are padded with silence to keep the track
on the shared timeline. Automatically detected meetings use a Core Audio process tap
(`AudioHardwareCreateProcessTap`, macOS 14.4+) scoped to the detected app, so unrelated audio is not
included. Manual recordings use a global system audio tap and include all system output.

A saved recording can contain the following files. Both audio tracks are normalized to 16 kHz mono
and written separately:

```text
~/Library/Application Support/MeetingHelper/Meetings/<uuid>/
    meeting.json     metadata
    mic.wav          my voice
    system.wav       the other participants' voices
    mix.m4a          mixdown for playback
    transcript.json  lines with timecodes and roles
```

Separate tracks provide the initial attribution without diarization: microphone speech is labelled
"Me", and the meeting app's audio is labelled "Others". Speaker playback can leak into the
microphone, so two additional stages refine that attribution.

### Echo gate

The echo gate runs before recognition. Because both tracks share a timeline, each microphone
utterance can be compared with the loudness envelope of the system track. Playback leakage repeats
the shape of the system audio after a short room delay and at a much lower level.

An utterance whose shape matches playback and sits at least 18 dB below it is treated as leakage and
does not reach Whisper. Louder speech that overlaps playback is designed to fail the level test and
be kept. With headphones, or without a system track, the gate simply does not fire.

The recording window shows how many utterances the gate has compared and filtered. The gate can be
disabled in Settings, which removes the reference buffer and the wait of up to half a second for the
system track to catch up. Thresholds and calibration measurements are documented in
[echo-gate-calibration.md](../knowledge/echo-gate-calibration.md).

### Transcript deduplication

Transcript deduplication runs after recognition. It compares near-simultaneous lines from the two
tracks and keeps the cleaner system-audio copy when both contain the same speech. It catches leakage
that passed the echo gate, while the echo gate handles cases where the two tracks produce different
words for the same speech. Deduplication is enabled by default and can be disabled in Settings.

## Transcription

Transcription uses WhisperKit and Core ML. The model is selected in Settings, with
`openai_whisper-large-v3-v20240930_turbo` as the default. Model files are stored under:

```text
~/Library/Application Support/MeetingHelper/Models
```

Whisper is not a streaming model, so an energy-based VAD with an adaptive threshold divides each
track into utterances. An utterance closes after 0.8 seconds of silence or is forced closed after 25
seconds. Each track has its own transcriber, and both use a shared actor that owns the model.

Optional real-time updates recognize an expanding, overlapping audio snapshot every two seconds.
Each result updates a preview line in place. After a pause, the full-utterance result replaces the
preview, and only the final line is saved. This mode is disabled by default because it uses more
processing power.

While a recording is active, utterances that arrive before the model is ready wait for the current
model load instead of being dropped. If the recording stops before the model becomes ready, that
pending transcription work is discarded so stopping does not wait for the download. The model can
be downloaded in advance from Settings. On later launches, the app loads the local files and
prepares Core ML without contacting the model repository.

## Permission handling

The app is intentionally not sandboxed because process-scoped audio taps and the Accessibility API
are unavailable under App Sandbox.

System audio access has no public API for checking its state. Process bundle IDs remain visible
without permission, and `AudioHardwareCreateProcessTap` returns `noErr` when access is denied while
delivering silence. Meeting Helper reads the state through the TCC SPI. As a fallback,
`RecordingSession` shows a warning when the tap remains near-silent for 20 seconds.
