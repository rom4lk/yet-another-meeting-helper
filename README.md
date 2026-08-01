# Meeting Helper

A native macOS meeting recorder and transcription app. Meeting Helper can detect a meeting, start
and stop recording automatically, and keep a live transcript visible while you work in another app.

## Features

- Automatic meeting detection for Zoom and Google Meet in Chrome, Arc, Edge, and Safari.
- Separate microphone and meeting-audio tracks, labelled as "Me" and "Others" in the transcript.
- On-device transcription with WhisperKit or multilingual Parakeet TDT v3.
- An optional always-on-top transcript panel with real-time preview updates.
- Echo filtering and transcript deduplication for cleaner speaker attribution.
- Process-scoped audio capture for detected meetings, plus manual recording of all system audio.
- Saved recordings, playback, transcripts, timestamps, and meeting metadata.
- Global shortcuts for starting a recording and showing or hiding the transcript panel.

## Build

Requirements: macOS 14.4+, Xcode 16+, XcodeGen, an internet connection, and an Apple Account added
to Xcode. A free Personal Team is enough to build and run the app on your own Mac.

Install Xcode from the App Store, open it once so it can install its components, then install
XcodeGen:

```bash
brew install xcodegen
```

Clone the repository and generate the Xcode project:

```bash
git clone https://github.com/rom4lk/yet-another-meeting-helper.git
cd yet-another-meeting-helper
xcodegen generate
open MeetingHelper.xcodeproj
```

`.xcodeproj` is generated from [project.yml](project.yml) and is not stored in git.

Before the first build, configure signing in Xcode:

1. Open **Xcode > Settings > Accounts** and add your Apple Account.
2. Select the **MeetingHelper** target, then open **Signing & Capabilities**.
3. Keep **Automatically manage signing** enabled and select your team.
4. If Xcode says the bundle identifier is unavailable, replace `com.kovalev.MeetingHelper` with a
   unique value such as `com.yourname.MeetingHelper`.

Select the **MeetingHelper** scheme and **My Mac**, then press **Command-R**. The first build can take
a few minutes while Xcode downloads the transcription dependencies.

The app must remain code signed because macOS privacy permissions are tied to its code identity.
The project rejects builds made with `CODE_SIGNING_ALLOWED=NO`. Regenerating the project can reset
your local signing selection, so check it again after running `xcodegen generate`.

### Build and run from the terminal

Create the ignored local signing configuration once and replace `YOUR_TEAM_ID` with the Apple
Development team shown in Xcode under **Settings > Accounts**:

```bash
cp Config/LocalSigning.xcconfig.example Config/LocalSigning.xcconfig
```

Then generate, build, and run from the repository root:

```bash
xcodegen generate &&
xcodebuild \
  -project MeetingHelper.xcodeproj \
  -scheme MeetingHelper \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build \
  -allowProvisioningUpdates \
  build &&
{ pkill -x MeetingHelper 2>/dev/null || true; } &&
open .build/Build/Products/Debug/MeetingHelper.app
```

The Debug app is development-signed for local use. It is not Developer ID-signed or notarized for
distribution. Meeting Helper rejects ad-hoc builds because their identity changes on every rebuild
and causes macOS to request privacy permissions again.

### First run

Grant access to the microphone, system audio recording, and Accessibility when macOS asks. If you
previously denied a permission, enable it under **System Settings > Privacy & Security** and restart
the app.

Open Settings in Meeting Helper and download the transcription model before the first meeting. The
default model is about 1.5 GB and is not included in the app bundle.

To check the installation, start a manual recording with **Option-Command-R**, speak into the
microphone, play some system audio, stop the recording, and verify both tracks in the saved meeting.

## How it works

Meeting Helper detects Zoom directly and identifies Google Meet calls in Chrome, Arc, Edge, and
Safari using microphone activity and window titles.

Automatic recordings capture audio only from the detected meeting app. Manual recordings capture
all system audio. The microphone and meeting audio are stored separately, which lets the transcript
distinguish "Me" from "Others".

Transcription runs locally with WhisperKit or Parakeet TDT v3. Echo filtering and transcript
deduplication reduce speaker leakage and duplicate lines. See
[docs/how-it-works.md](docs/how-it-works.md) for the implementation details.

## Permissions

| Permission | What for | Without it |
|---|---|---|
| Microphone | own track | recording does not start |
| System audio | the other participants' track | silence in the second track |
| Accessibility | window titles | no meeting titles and no Google Meet detection |

The app is deliberately **not sandboxed**: process-bound taps and the Accessibility API are not
available under App Sandbox.

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

Transcription has not been verified either: the test meeting lasted 20 seconds, and the selected
model did not finish downloading in that time. Model downloads are one-off.
