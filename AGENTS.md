# AGENTS.md

## Language

Everything in this repository is written in English: code, comments, identifiers, commit messages,
documentation, and **all user-facing strings** — window and menu titles, buttons, labels, error
messages, placeholders, and the `NS*UsageDescription` entries in [project.yml](project.yml) and
[Resources/Info.plist](Resources/Info.plist). The app interface is English-only; there is no
localization and no Russian UI.

One exception: the hallucination filter in
[Sources/MeetingsHelper/Transcription/TranscriptionEngine.swift](Sources/MeetingsHelper/Transcription/TranscriptionEngine.swift)
holds verbatim Whisper output in the languages the model produces it in. Those strings are data
being matched against — never translate them.

Transcript content is whatever the meeting participants said, in whatever language they said it —
that is user data, not interface text.

Note that `project.yml` is the source of truth for the usage descriptions: `xcodegen generate`
rewrites `Resources/Info.plist` from it, so an edit made only in the plist gets overwritten.
