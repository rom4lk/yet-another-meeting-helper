# Meeting Helper

A native macOS meeting recorder and transcription app. Meeting Helper can detect a meeting, start
and stop recording automatically, and keep a live transcript visible while you work in another app.

## Features

- Automatic meeting detection for Zoom, and for Google Meet and Ktalk in Chrome, Arc, Edge, and
  Safari.
- Separate microphone and meeting-audio tracks, labelled as "Me" and "Others" in the transcript.
- On-device transcription with WhisperKit or multilingual Parakeet TDT v3.
- An optional always-on-top transcript panel with real-time preview updates.
- Your own speech can be hidden from the live transcript at any time, including during a call. The
  saved transcript keeps every line.
- Echo filtering and transcript deduplication for cleaner speaker attribution.
- Process-scoped audio capture for detected meetings, plus manual recording of all system audio.
- Saved recordings, playback, transcripts, timestamps, and meeting metadata.
- Optional read-only calendar integration covering every account macOS syncs, such as a work Google
  account and a personal one. A recording takes the name of the calendar event it belongs to and
  keeps that event's list of participants.
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

With `Config/LocalSigning.xcconfig` in place, run [run.sh](run.sh) from the repository root. It
regenerates the Xcode project, builds the app, quits the running copy, and launches the new one:

```bash
./run.sh
```

Pass `--release` to build the Release configuration instead of Debug.

The Debug app is development-signed for local use. It is not Developer ID-signed or notarized for
distribution. Meeting Helper rejects ad-hoc builds because their identity changes on every rebuild
and causes macOS to request privacy permissions again.

### First run

Grant access to the microphone, system audio recording, and Accessibility when macOS asks. If you
previously denied a permission, enable it under **System Settings > Privacy & Security** and restart
the app.

Open Settings in Meeting Helper and download the transcription model before the first meeting. No
model is included in the app bundle. The default is Whisper large-v3 turbo (about 1.5 GB); full
Whisper large-v3 (about 3 GB) is more accurate but noticeably slower, and Parakeet TDT v3 (about
600 MB) is the fastest.

### Synchronize meetings through iCloud Drive

Synchronization is off by default. In **Settings > iCloud**, choose a dedicated folder inside
iCloud Drive, then choose how many of the newest meetings to keep synchronized: 10, 30, 50, or all
meetings. The same folder must be selected in Meeting Helper on every Mac.

The selected limit applies to the combined set of meetings found on the Mac and in the sync folder.
Meetings beyond the limit remain in the local library but are removed from the sync folder. Turning
synchronization off does not delete copies already in that folder.

### Connect a calendar

Calendar integration is off until you grant access. It is read-only: Meeting Helper names a
recording after the event it belongs to and saves that event's list of participants with the
meeting. It never writes to a calendar.

The app has no sign-in of its own and needs no Google Cloud project. It reads the calendars macOS
already syncs, so both the work account and the personal one are added the ordinary way:

1. Open **System Settings > Internet Accounts**, add each Google account, and turn **Calendars** on
   for it. Accounts already added for Mail or Contacts only need the Calendars switch.
2. In Meeting Helper, open **Settings > Calendar** and press **Connect Calendar**. macOS asks for
   permission; the accounts it found are listed once it is granted.

Every calendar of every account is read, in a window from one hour back to three hours ahead of the
recording. If access was refused earlier, macOS will not ask again — the same section links to
**Privacy & Security > Calendars**, where it can be turned back on.

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
deduplication reduce speaker leakage and duplicate lines.

When calendar access is granted, a starting recording is matched to a calendar event by the
conference link, the title, and the time. Events are read locally through EventKit, so nothing in
the app talks to a network service and everything stays on the Mac. See
[docs/how-it-works.md](docs/how-it-works.md) for the implementation details.

## Permissions

| Permission | What for | Without it |
|---|---|---|
| Microphone | own track | recording does not start |
| System audio | the other participants' track | silence in the second track |
| Accessibility | window titles | no meeting titles and no browser meeting detection |
| Calendars (optional) | event names and participants | recordings keep the window title and no participants |

The app is deliberately **not sandboxed**: process-bound taps and the Accessibility API are not
available under App Sandbox.

## Shortcuts

- `⌥⌘R` — start/stop recording
- `⌥⌘T` — show/hide the floating panel
