# Meeting Helper

A native macOS meeting recorder and transcription app. Meeting Helper can detect a meeting, start
and stop recording automatically, and keep a live transcript visible while you work in another app.

## Features

- Automatic meeting detection for Zoom, and for Google Meet and Ktalk in Chrome, Arc, Edge, and
  Safari.
- Separate microphone and meeting-audio tracks, labelled as "Me" and "Others" in the transcript.
- On-device transcription with WhisperKit or multilingual Parakeet TDT v3.
- An optional always-on-top transcript panel with real-time preview updates.
- Echo filtering and transcript deduplication for cleaner speaker attribution.
- Process-scoped audio capture for detected meetings, plus manual recording of all system audio.
- Saved recordings, playback, transcripts, timestamps, and meeting metadata.
- Optional synchronization through a user-selected iCloud Drive or other file-syncing folder.
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

Before the first build, configure signing:

1. Open **Xcode > Settings > Accounts** and add your Apple Account, then copy your team ID from
   there.
2. Create the ignored local signing configuration and put that team ID in it:

   ```bash
   cp Config/LocalSigning.xcconfig.example Config/LocalSigning.xcconfig
   ```

3. If Xcode says the bundle identifier is unavailable, replace `com.kovalev.MeetingHelper` in
   [project.yml](project.yml) with a unique value such as `com.yourname.MeetingHelper`.

`Config/LocalSigning.xcconfig` is the only durable place for the team ID: selecting a team in
Xcode's **Signing & Capabilities** tab writes it into the generated `.xcodeproj`, which the next
`xcodegen generate` overwrites.

Select the **MeetingHelper** scheme and **My Mac**, then press **Command-R**. The first build can take
a few minutes while Xcode downloads the transcription dependencies.

The app must remain code signed because macOS privacy permissions are tied to its code identity.
The project rejects builds made with `CODE_SIGNING_ALLOWED=NO`.

### Build and run from the terminal

With `Config/LocalSigning.xcconfig` in place, generate, build, and run from the repository root:

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

### Synchronize meetings through iCloud Drive

Synchronization is off by default. In **Settings > iCloud**, choose a dedicated folder inside
iCloud Drive, then choose how many of the newest meetings to keep synchronized: 10, 30, 50, or all
meetings. The same folder must be selected in Meeting Helper on every Mac.

The selected limit applies to the combined set of meetings found on the Mac and in the sync folder.
Meetings beyond the limit remain in the local library but are removed from the sync folder. Turning
synchronization off does not delete copies already in that folder.

To check the installation, start a manual recording with **Option-Command-R**, speak into the
microphone, play some system audio, stop the recording, and verify both tracks in the saved meeting.

## How it works

Meeting Helper detects Zoom directly and identifies Google Meet and Ktalk calls in Chrome, Arc,
Edge, and Safari using microphone activity and window titles. Ktalk is recognized on any host,
including an organization's own one such as `example.ktalk.ru`.

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
| Accessibility | window titles | no meeting titles and no browser meeting detection |

The app is deliberately **not sandboxed**: process-bound taps and the Accessibility API are not
available under App Sandbox.

## Shortcuts

- `⌥⌘R` — start/stop recording
- `⌥⌘T` — show/hide the floating panel
