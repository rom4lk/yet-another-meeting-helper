# How Meeting Helper Works

This document describes the implementation behind meeting detection, audio capture, speaker
attribution, and transcription. For installation and usage, see the [README](../README.md).

## Meeting detection

Meeting Helper combines three signals, from precise to general.

| Layer | Signal | What it covers |
|---|---|---|
| Meeting process | Presence of `us.zoom.CptHost` | Zoom, native client |
| Process audio activity | `kAudioProcessPropertyIsRunningInput` over a bundle ID family | The browser is holding the microphone |
| Window title | Accessibility API | Distinguishes a meeting tab from other tabs and provides the meeting title |

Zoom spawns the `CptHost` helper process for the duration of a conference and terminates it when the
user leaves. This gives the app a precise start and end signal, unlike general microphone activity,
which also occurs during dictation and audio checks.

`CptHost` must be polled. It is an agent (`LSUIElement`), and `NSWorkspace` does not post
`didLaunchApplicationNotification` or `didTerminateApplicationNotification` for agents. They appear
in `runningApplications`, but no lifecycle notifications arrive for them. A live test confirmed that
leaving a conference produced a notification for `us.zoom.xos` but not for `us.zoom.CptHost`.

Browser meetings do not have an equivalent helper process. Meeting Helper therefore requires both
microphone activity and a window that one of the `BrowserMeetingService` entries claims. Without
Accessibility access, browser meeting detection is unavailable, while Zoom detection continues to
work.

Each service is described by a title test and the host of its installed PWA:

| Service | Window title | PWA host |
|---|---|---|
| Google Meet | Names Google Meet, or carries a meeting code such as `abc-defg-hij` | `meet.google.com` |
| Ktalk | Ends with the client's own app name, which it emits untranslated in every locale | `ktalk.ru` and any subdomain of it, such as an organization's `example.ktalk.ru` |

The Ktalk web client builds the document title as either its app name alone or
`<page> — <app name>`, so that name is the only stable marker a title carries. It is anchored to the
end of the title rather than searched for anywhere inside it, because as a bare substring the name
also occurs inside unrelated words, and such a tab would then claim a browser that is holding the
microphone for a real meeting elsewhere.

A PWA window has no title to read: Chrome exposes neither `AXTitle` nor `AXDocument` for one. Its
bundle records the URL it was installed from, so the host taken from `CrAppModeShortcutURL`
identifies the service, while the Accessibility API only confirms that a real window exists.
Subdomains match the configured host, which is what covers a Ktalk instance of an individual
organization.

Stopping a recording drains the transcription backlog and writes the mixdown, which can take a
minute on a long meeting. A meeting detected in that window is remembered and started once the
previous session is gone. Dropping it instead would lose it for good: the detector has already
recorded it as the current meeting and never reports the same start twice. The remembered meeting is
started only if the detector still reports it as running, so a short call that begins and ends inside
that window is not recorded after the fact.

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

### Folder-based synchronization

The local Application Support directory remains the working library. Recording never writes into a
cloud-backed directory, so a slow or offline sync service cannot interrupt audio capture. After a
meeting is completely saved, the app can mirror its directory into a user-selected folder, normally
one inside iCloud Drive:

```text
<selected folder>/
    Meetings/<uuid>/       complete meeting directories
    DeletedMeetings/       small deletion markers
```

The folder is stored as a macOS bookmark. No app-owned iCloud container or iCloud entitlement is
required; iCloud Drive, Dropbox, or another provider is responsible for moving the ordinary files
between Macs. The app reconciles the folder after a local change, whenever it becomes active, and
every 30 seconds while synchronization is enabled.

The retention setting is disabled by default and supports the newest 10, 30, 50, or all meetings.
The limit is applied to the union of valid local and remote meeting metadata. Older remote copies
are removed from the sync folder, while local copies are retained. A meeting present on only the
remote side is downloaded when it belongs to the retained set.

Meeting UUIDs prevent independently recorded meetings from colliding. If the same meeting changes
on two Macs, the newer side wins, where "newer" is the most recent modification date among the files
in the directory rather than the metadata alone — a transcript can change while `meeting.json` stays
exactly as it was. The winning side is then mirrored file by file: only files whose size or
modification date differ are copied, and files the source no longer has are removed. A meeting
directory is mostly audio that never changes once the recording is saved, so editing a title
transfers a few hundred bytes instead of the whole recording. Each file is staged on the destination
volume and installed in one step, so no file is ever observed half written.
Meeting kinds written by newer app versions are preserved and shown as "Other" when the current
version does not recognize them. Missing metadata in the sync folder, or unreadable or inconsistent
metadata on either side, fails the synchronization pass instead of being skipped with an up-to-date
status. An in-progress local recording without metadata is ignored until it is completely saved.
App-initiated deletion creates a permanent marker before removing the synchronized copy; this keeps
an offline Mac from uploading an old local copy again later. Turning synchronization off stops
reconciliation but deliberately leaves the current contents of the selected folder unchanged.

Reconciliation runs on a private serial queue rather than on Swift's cooperative thread pool. The
copies can block for minutes on a cold iCloud folder, and that pool holds only a handful of threads
shared with transcription. The queue being serial is also what keeps a recorded deletion from
interleaving with a reconciliation already in progress.

This feature is synchronization, not an independent backup. The selected provider must have enough
space for the audio files, and manually editing or deleting files inside the sync folder can bypass
the app's conflict and deletion rules. A live two-Mac test is still required for every supported
provider because download timing and placeholder behavior are controlled by that provider.

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

### Hiding your own speech

The live transcript can leave the microphone lines out and show only the other participants. This
affects the display alone: the microphone is still captured, recognized, and written to the saved
transcript, so switching the lines back on brings the hidden ones with it.

Unlike the other transcript options, this switch is read every time the live views redraw instead of
being captured when the recording starts, which is what lets it be flipped mid-call. It is available
in Settings, in the header of the recording window, and in the floating panel header, where the eye
icon next to "Me" also shows the current state.

## Transcription

Transcription uses Core ML through either WhisperKit or FluidAudio. Settings offers Whisper
large-v3 turbo and multilingual Parakeet TDT v3, with Whisper as the default. Whisper model files
are stored under:

```text
~/Library/Application Support/MeetingHelper/Models
```

Parakeet uses FluidAudio's model cache under `~/Library/Application Support/FluidAudio/Models`.
Both backends process complete audio buffers, so an energy-based VAD with an adaptive threshold
divides each track into utterances. An utterance closes after 0.8 seconds of silence or is forced
closed after 25 seconds. Each track has its own transcriber, and both use a shared actor that owns
the selected model.

Optional real-time updates recognize an expanding, overlapping audio snapshot every two seconds.
Each result updates a preview line in place. After a pause, the full-utterance result replaces the
preview, and only the final line is saved. This mode is disabled by default because it uses more
processing power.

While a recording is active, utterances that arrive before the model is ready wait for the current
model load instead of being dropped. If the recording stops before the model becomes ready, that
pending transcription work is discarded so stopping does not wait for the download. The model can
be downloaded in advance from Settings. On later launches, the app loads the local files and
prepares Core ML without contacting the model repository. The interface distinguishes device
optimization from loading the optimized model into memory. Core ML does not expose progress within
device optimization; the first optimization can take 10 minutes or more, while the subsequent load
usually takes a few seconds. macOS caches the optimized model, so later launches are normally much
faster unless the system cache has been evicted.

## Permission handling

The app is intentionally not sandboxed because process-scoped audio taps and the Accessibility API
are unavailable under App Sandbox.

Local builds use an Apple Development identity configured in the ignored
`Config/LocalSigning.xcconfig` file. A stable signing identity is required because macOS privacy
permissions are tied to the app's designated code requirement; ad-hoc signatures change whenever
the executable changes and therefore invalidate previously granted access.

System audio access has no public API for checking its state. Process bundle IDs remain visible
without permission, and `AudioHardwareCreateProcessTap` returns `noErr` when access is denied while
delivering silence. Meeting Helper reads the state through the TCC SPI. As a fallback,
`RecordingSession` shows a warning when the tap remains near-silent for 20 seconds.

The app requests only the microphone, system audio recording and Accessibility. It holds no
calendar or Apple Events entitlement, and nothing in the code reaches for either.

When a meeting starts without microphone access, the detector keeps its state instead of clearing
it. Clearing would let the two-second poll re-fire the start immediately, raising the same alert
once per poll for the whole meeting; keeping it means the failure is reported once, and recording
can be started by hand after the permission is granted.

## Logging and privacy

Recordings, transcripts and metadata never leave the machine unless a sync folder is configured.

Meeting titles and transcript text are user data and are logged with `privacy: .private`, so they
appear as `<private>` in `log show` and Console. Only non-identifying values — the meeting kind,
permission states, audio formats, error descriptions — are logged as `.public`, which is what makes
a missed meeting debuggable after the fact without exposing what was said.
