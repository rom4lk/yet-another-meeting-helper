import AppKit
import SwiftUI

struct MeetingDetailView: View {
    @EnvironmentObject private var controller: AppController
    @StateObject private var player = AudioPlayerModel()

    let meeting: Meeting

    @State private var title: String = ""
    @State private var lines: [TranscriptLine] = []
    @State private var isShowingDeleteConfirmation = false

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
        .onDisappear { player.stop() }
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
                TextField("Meeting title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .onSubmit(saveTitle)

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

            Text("\(FloatingTranscriptView.format(player.currentTime)) / \(FloatingTranscriptView.format(player.duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var icon: String {
        switch meeting.kind {
        case .zoom: return "video.fill"
        case .googleMeet: return "globe"
        case .manual: return "hand.tap.fill"
        }
    }

    private func load() {
        title = meeting.title
        lines = controller.store.transcript(for: meeting.id)
        player.load(url: MeetingLibrary.mixdownURL(for: meeting.id))
    }

    private func saveTitle() {
        var updated = meeting
        updated.title = title
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
        let text = lines
            .map { "[\($0.timestamp)] \($0.source.title): \($0.text)" }
            .joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
