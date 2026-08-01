import SwiftUI

enum SidebarItem: Hashable {
    case active
    case meeting(UUID)
}

struct RootView: View {
    @EnvironmentObject private var controller: AppController
    @State private var selection: SidebarItem?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    controller.toggleRecording()
                } label: {
                    Label(
                        controller.isRecording ? "Stop" : "Record",
                        systemImage: controller.isRecording ? "stop.circle.fill" : "record.circle"
                    )
                }
                .help(controller.isRecording ? "Stop recording (⌥⌘R)" : "Start recording manually (⌥⌘R)")
                .disabled(controller.isStopping)
            }
        }
        .onChange(of: controller.isRecording) { _, isRecording in
            selection = isRecording ? .active : selection
        }
        .alert("Error", isPresented: Binding(
            get: { controller.errorMessage != nil },
            set: { if !$0 { controller.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { controller.errorMessage = nil }
        } message: {
            Text(controller.errorMessage ?? "")
        }
    }

    // Note: do not add `.navigationSplitViewColumnWidth` here — on macOS 15 it collapses the
    // sidebar content to nothing while keeping the column visible.
    private var sidebar: some View {
        List(selection: $selection) {
            if let session = controller.session {
                Section("Now") {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title).lineLimit(1)
                            Text(FloatingTranscriptView.format(session.elapsed))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Circle().fill(.red).frame(width: 8, height: 8)
                    }
                    .tag(SidebarItem.active)
                }
            }

            Section("Meetings") {
                ForEach(controller.store.meetings) { meeting in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meeting.title).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                            Text(meeting.formattedDuration).monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .tag(SidebarItem.meeting(meeting.id))
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            controller.store.delete(meeting)
                        }
                    }
                }
            }

            PermissionsBanner()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .active:
            if let session = controller.session {
                ActiveRecordingView(session: session)
            } else {
                placeholder
            }
        case .meeting(let id):
            if let meeting = controller.store.meetings.first(where: { $0.id == id }) {
                MeetingDetailView(meeting: meeting)
            } else {
                placeholder
            }
        case nil:
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "video.badge.waveform")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("When a Zoom meeting starts, recording starts on its own.")
                .foregroundStyle(.secondary)
            Text("Or press ⌥⌘R to record something manually.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Sits at the bottom of the sidebar and only appears when something is actually missing.
private struct PermissionsBanner: View {
    @EnvironmentObject private var controller: AppController

    private var hasIssues: Bool {
        !controller.microphoneGranted
            || controller.systemAudioPermission != .authorized
            || !controller.accessibilityGranted
    }

    var body: some View {
        if hasIssues {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.quaternary.opacity(0.4))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !controller.microphoneGranted {
                row("No microphone access", action: "Allow") {
                    controller.requestMicrophonePermission()
                }
            }
            if controller.systemAudioPermission != .authorized {
                row("No system audio access", action: "Allow") {
                    controller.requestSystemAudioPermission()
                }
            }
            if !controller.accessibilityGranted {
                row("Without Accessibility, meeting titles and Google Meet stay invisible", action: "Open") {
                    controller.requestAccessibilityPermission()
                }
            }
        }
    }

    private func row(_ text: String, action: String, handler: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action, action: handler)
                .buttonStyle(.link)
                .font(.caption)
        }
    }
}
