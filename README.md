# Meetings Helper

A native macOS app: it notices a meeting has started on its own, records the microphone and system
audio into separate tracks, and shows a live transcript in a floating window above everything else.

## Build

```bash
xcodegen generate && open MeetingsHelper.xcodeproj
```

`.xcodeproj` is not in git — it is generated from [project.yml](project.yml). After adding new files
to `Sources/`, the project has to be regenerated.

Requirements: macOS 14.4+ (Core Audio process taps), Xcode 16+, XcodeGen (`brew install xcodegen`).

The app must always be code signed because macOS privacy permissions are tied to its code identity.
The project rejects builds made with `CODE_SIGNING_ALLOWED=NO`; use the configured automatic signing
both from Xcode and from `xcodebuild`.

### Build and run from the terminal

From the repository root:

```bash
xcodegen generate &&
xcodebuild \
  -project MeetingsHelper.xcodeproj \
  -scheme MeetingsHelper \
  -configuration Debug \
  -derivedDataPath .build \
  build &&
{ pkill -x MeetingsHelper 2>/dev/null || true; } &&
open .build/Build/Products/Debug/MeetingsHelper.app
```

This regenerates the Xcode project, builds a signed Debug app, stops an already running instance,
and launches the new build. If `xcodebuild` reports a provisioning error, add
`-allowProvisioningUpdates` before `build`.

## How detection works

Three layers, from precise to general.

| Layer | Signal | What it covers |
|---|---|---|
| Meeting process | presence of `us.zoom.CptHost` | Zoom, native client |
| Process audio activity | `kAudioProcessPropertyIsRunningInput` over a bundle id family | the browser is holding the microphone |
| Window title | Accessibility API | tells Google Meet apart from any other tab, gives the meeting title |

The key detail about Zoom: the client spawns a helper process, `CptHost`, exactly for the duration
of the conference and kills it on leave. That is a precise signal of the meeting's start and end —
unlike "some app turned on the microphone", which also fires on dictation and on checking your audio
before joining.

This process has to be polled on a timer rather than subscribed to. `CptHost` is an agent
(`LSUIElement`), and `NSWorkspace` does not post `didLaunchApplicationNotification` or
`didTerminateApplicationNotification` for agents: they show up in `runningApplications`, but no
notifications arrive for them. Verified with a log: leaving a conference produced a notification for
`us.zoom.xos` only, and none for `us.zoom.CptHost`.

Browser meetings have no such process, so there both weak signals are needed at once: the browser
has grabbed the microphone **and** the window title looks like Google Meet. Without Accessibility
the second signal is unavailable, and browser meeting detection turns off — Zoom keeps working.

## How recording works

The microphone goes through `AVAudioEngine`, system audio through a Core Audio process tap
(`AudioHardwareCreateProcessTap`, macOS 14.4+) bound to the processes of the specific meeting app.
That is why music from another app never ends up in the recording.

Both tracks are normalized to 16 kHz mono and written **separately**:

```
~/Library/Application Support/MeetingsHelper/Meetings/<uuid>/
    meeting.json     metadata
    mic.wav          my voice
    system.wav       the other participants' voices
    mix.m4a          mixdown for playback
    transcript.json  lines with timecodes and roles
```

Separate tracks give speaker attribution without diarization: everything from the microphone is
"Me", everything from the app's audio stream is "Others".

## Transcript

WhisperKit (CoreML); the model is picked in Settings, `large-v3-turbo` by default. Model files live
under `~/Library/Application Support/MeetingsHelper/Models` and are prepared in the background when
the app starts. Whisper is not
streaming, so the stream is cut into lines by an energy VAD with an adaptive threshold: a line closes
after 0.8 s of silence, or is forced closed at 25 s. Each track is transcribed by its own instance,
and both go through a shared actor that holds the model.

Audio starts arriving before the model has finished loading, so the first chunks are not thrown away
— they wait for it in a queue. Settings has a "Download" button with progress to pull the files in
advance. On later launches the app uses the local files without contacting the model repository and
prepares Core ML before a meeting begins.

## Permissions

| Permission | What for | Without it |
|---|---|---|
| Microphone | own track | recording does not start |
| System audio | the other participants' track | silence in the second track |
| Accessibility | window titles | no meeting titles and no Google Meet detection |

The app is deliberately **not sandboxed**: process-bound taps and the Accessibility API are not
available under App Sandbox.

System audio access has no public API for checking its state, and the obvious probes lie: process
bundle ids can be read without the permission, and `AudioHardwareCreateProcessTap` returns `noErr`
when denied and simply hands back silence. So the status is read through the TCC SPI (the way AudioCap
and Hyprnote do it), and in case that ever disappears, `RecordingSession` independently notices that
the tap has been handing back zeros for 20 seconds and shows a warning.

## Shortcuts

- `⌥⌘R` — start/stop recording
- `⌥⌘T` — show/hide the floating panel

## What has been verified, and what has not

Verified in a live Zoom meeting: detection of the conference start and end, automatic start and stop
of recording, the microphone track (a real signal in the file), the mixdown, saving metadata.

Not verified: the system audio track — in the test meeting the other participants stayed silent, and
`system.wav` came out as digital silence. That recording cannot tell "nobody spoke" apart from "no
permission"; for that case the interface has a warning that appears if the tap hands back zeros for
20 seconds.

Transcription has not been verified either: the test meeting lasted 20 seconds, and the model did not
finish downloading in that time. The first recording pulls the Whisper model (~1.5 GB), which is a
one-off.
