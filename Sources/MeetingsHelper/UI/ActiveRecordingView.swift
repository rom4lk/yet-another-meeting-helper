import SwiftUI

struct ActiveRecordingView: View {
    @EnvironmentObject private var controller: AppController
    @ObservedObject var session: RecordingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if session.sortedLines.isEmpty {
                status
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TranscriptView(lines: session.sortedLines, autoScroll: true)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)

                TextField("Meeting title", text: $session.title)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))

                Spacer()

                Text(FloatingTranscriptView.format(session.elapsed))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button(controller.isPanelVisible ? "Hide panel" : "Show panel") {
                    controller.togglePanel()
                }

                Button("Stop") {
                    controller.stopRecording()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(controller.isStopping)
            }

            HStack(spacing: 20) {
                LevelMeter(title: "Microphone", level: session.micLevel, isActive: session.micState == .capturing)
                LevelMeter(title: "System audio", level: session.systemLevel, isActive: session.systemState == .capturing)
            }

            if session.systemSilent {
                HStack {
                    Label("No system audio is coming in — the permission is most likely missing.", systemImage: "exclamationmark.triangle.fill")
                    Button("Open Settings") { SystemAudioPermission.openSystemSettings() }
                        .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if case .unavailable(let message) = session.systemState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if case .unavailable(let message) = session.micState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var status: some View {
        VStack(spacing: 8) {
            switch session.transcriptionState {
            case .downloading(let progress):
                if let progress {
                    ProgressView(value: progress).frame(width: 180)
                    Text("Downloading the speech recognition model — \(progress.formatted(.percent.precision(.fractionLength(0))))")
                } else {
                    ProgressView().controlSize(.small)
                    Text("Starting the speech recognition model download…")
                }
            case .preparing:
                ProgressView().controlSize(.small)
                Text("Preparing speech recognition…")
            case .running:
                Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.tertiary)
                Text("Listening. Lines will show up here a couple of seconds after the first phrase.")
            case .disabled:
                Image(systemName: "waveform.slash").font(.largeTitle).foregroundStyle(.tertiary)
                Text("Live transcript is off. Audio is still being recorded.")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text("Recognition unavailable: \(message)")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
        .padding()
    }
}
