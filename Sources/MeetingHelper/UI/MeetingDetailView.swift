import AppKit
import SwiftUI

struct MeetingDetailView: View {
    @EnvironmentObject private var controller: AppController
    @StateObject private var player = AudioPlayerModel()

    let meeting: Meeting

    @State private var title: String = ""
    @State private var lines: [TranscriptLine] = []
    @State private var isShowingDeleteConfirmation = false
    @State private var editingMeetingID: UUID?
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if lines.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.alignleft").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("No transcript — the recording was saved as audio only.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TranscriptView(lines: lines)
            }
        }
        .onAppear(perform: load)
        .onChange(of: meeting.id) { _, _ in load() }
        .onDisappear {
            saveTitle()
            player.stop()
        }
        .confirmationDialog(
            "Delete long meeting?",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Meeting", role: .destructive) {
                controller.store.delete(meeting)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This meeting is longer than 5 minutes. Deleting it permanently removes its recording and transcript.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                // Committing on focus loss as well as on Return: clicking away from the field is
                // the ordinary way to finish an edit, and it used to discard it silently.
                TextField("Meeting title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .focused($isTitleFocused)
                    .onSubmit(saveTitle)
                    .onChange(of: isTitleFocused) { wasFocused, isFocused in
                        if wasFocused, !isFocused { saveTitle() }
                    }

                Spacer()

                Menu {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([MeetingLibrary.directory(for: meeting.id)])
                    }
                    Button("Copy transcript") { copyTranscript() }
                        .disabled(lines.isEmpty)
                    Divider()
                    Button("Delete meeting", role: .destructive) {
                        deleteMeeting()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 40)
            }

            HStack(spacing: 12) {
                Label(meeting.kind.displayName, systemImage: icon)
                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                Text(meeting.formattedDuration)
                if let model = meeting.transcriptionModel {
                    Label(
                        "Transcription: \(AppSettings.displayName(forModel: model))",
                        systemImage: "waveform"
                    )
                }
                if let calendar = meeting.calendar {
                    CalendarParticipantsLabel(info: calendar)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if player.isAvailable {
                playerControls
            }
        }
        .padding(20)
    }

    private var playerControls: some View {
        HStack(spacing: 12) {
            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 20)
            }
            .buttonStyle(.borderless)

            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 0.1)
            )

            Text("\(player.currentTime.clockString) / \(player.duration.clockString)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var icon: String {
        switch meeting.kind {
        case .zoom: return "video.fill"
        case .googleMeet, .ktalk: return "globe"
        case .manual: return "hand.tap.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private func load() {
        title = meeting.title
        editingMeetingID = meeting.id
        lines = controller.store.transcript(for: meeting.id)
        player.load(url: MeetingLibrary.mixdownURL(for: meeting.id))
    }

    /// The id guard matters because the view is reused across selections: a save triggered while
    /// the selection is already moving must not write the previous meeting's text onto the new one.
    private func saveTitle() {
        guard editingMeetingID == meeting.id else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != meeting.title else { return }

        var updated = meeting
        updated.title = trimmed
        controller.store.save(updated)
    }

    private func deleteMeeting() {
        if meeting.requiresDeletionConfirmation {
            isShowingDeleteConfirmation = true
        } else {
            controller.store.delete(meeting)
        }
    }

    private func copyTranscript() {
        let text = TranscriptTextFormatter.string(
            from: lines,
            transcriptionModel: meeting.transcriptionModel
        )

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
