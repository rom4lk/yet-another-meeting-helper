import SwiftUI

enum SidebarItem: Hashable {
    case active
    case meeting(UUID)
}

private enum SidebarScrollTarget: Hashable {
    case topInset
}

struct RootView: View {
    @EnvironmentObject private var controller: AppController
    @State private var selection: SidebarItem?
    @State private var meetingPendingDeletion: Meeting?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                modelStatus

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

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open settings (⌘,)")
                .accessibilityIdentifier("settings-button")
            }
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

    @ViewBuilder
    private var modelStatus: some View {
        switch controller.modelState {
        case .downloading(let progress):
            HStack(spacing: 6) {
                if let progress {
                    ProgressView(value: progress)
                        .frame(width: 72)
                    Text("Downloading model \(progress.formatted(.percent.precision(.fractionLength(0))))")
                        .monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                    Text("Starting model download…")
                }
            }
            .foregroundStyle(.secondary)
        case .preparing(let stage):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(stage.statusText)
            }
            .foregroundStyle(.secondary)
            .help(stage.detailText)
        case .failed(let message):
            Label("Model unavailable", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(message)
        case .missing, .installed:
            EmptyView()
        }
    }

    // Note: do not add `.navigationSplitViewColumnWidth` here — on macOS 15 it collapses the
    // sidebar content to nothing while keeping the column visible.
    private var sidebar: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                if let session = controller.session {
                    // A real first row gives scrollTo a stable target and leaves room for the
                    // section header below the window toolbar.
                    Color.clear
                        .frame(height: 8)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .accessibilityHidden(true)
                        .id(SidebarScrollTarget.topInset)

                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title).lineLimit(1)
                                Text(session.elapsed.clockString)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Circle().fill(.red).frame(width: 8, height: 8)
                        }
                        .tag(SidebarItem.active)
                    } header: {
                        Text("Now")
                            .accessibilityIdentifier("sidebar-now-header")
                    }
                }

                Section {
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
                                deleteMeeting(meeting)
                            }
                        }
                    }
                } header: {
                    Text("Meetings")
                        .accessibilityIdentifier("sidebar-meetings-header")
                }

                PermissionsBanner()
            }
            .onChange(of: controller.isRecording) { _, isRecording in
                guard isRecording else { return }

                // macOS preserves the viewport when content is prepended. Reset it after the
                // recording section exists, then select the active row.
                DispatchQueue.main.async {
                    proxy.scrollTo(SidebarScrollTarget.topInset, anchor: .top)
                    selection = .active
                }
            }
            .confirmationDialog(
                "Delete long meeting?",
                isPresented: Binding(
                    get: { meetingPendingDeletion != nil },
                    set: { if !$0 { meetingPendingDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: meetingPendingDeletion
            ) { meeting in
                Button("Delete Meeting", role: .destructive) {
                    controller.store.delete(meeting)
                    meetingPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) {
                    meetingPendingDeletion = nil
                }
            } message: { _ in
                Text("This meeting is longer than 5 minutes. Deleting it permanently removes its recording and transcript.")
            }
        }
    }

    private func deleteMeeting(_ meeting: Meeting) {
        if meeting.requiresDeletionConfirmation {
            meetingPendingDeletion = meeting
        } else {
            controller.store.delete(meeting)
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
                row("Without Accessibility, meeting titles and browser meetings stay invisible", action: "Open") {
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
