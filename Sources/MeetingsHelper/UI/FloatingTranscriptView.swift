import SwiftUI

/// Content of the always-on-top panel.
struct FloatingTranscriptView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let session = controller.session {
                if session.sortedLines.isEmpty {
                    placeholder(for: session)
                } else {
                    TranscriptView(lines: session.sortedLines, compact: true, autoScroll: true)
                }
            } else {
                Text("Not recording")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.ultraThinMaterial)
        .frame(minWidth: 320, minHeight: 180)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if controller.isRecording {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
            }

            Text(controller.session?.title ?? "Meetings Helper")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            Spacer()

            if let session = controller.session {
                Text(Self.format(session.elapsed))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)

                Button {
                    controller.stopRecording()
                } label: {
                    Image(systemName: "stop.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help("Stop recording")
            }

            Button {
                controller.hidePanel()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Hide the panel (⌥⌘T)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func placeholder(for session: RecordingSession) -> some View {
        VStack(spacing: 6) {
            switch session.transcriptionState {
            case .preparing:
                ProgressView().controlSize(.small)
                Text("Loading the speech recognition model…")
            case .running:
                Text("Listening…")
            case .disabled:
                Text("Live transcript is off in Settings")
            case .failed(let message):
                Text("Recognition error")
                Text(message).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}
