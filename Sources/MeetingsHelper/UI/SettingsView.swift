import SwiftUI

struct SettingsView: View {
    private static let recordingDurationLabels = [
        5: "5 seconds",
        10: "10 seconds",
        30: "30 seconds",
        60: "1 minute",
        300: "5 minutes"
    ]

    @EnvironmentObject private var controller: AppController

    var body: some View {
        Form {
            Section("Detection") {
                Toggle("Start recording automatically when a meeting begins", isOn: Binding(
                    get: { controller.settings.autoDetectionEnabled },
                    set: {
                        controller.settings.autoDetectionEnabled = $0
                        controller.detector.autoDetectionEnabled = $0
                    }
                ))
                Text("Zoom is detected by its meeting helper process, Google Meet — by the browser microphone and the tab title.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recording") {
                Picker("Minimum duration", selection: Binding(
                    get: { controller.settings.minimumRecordingDuration },
                    set: { controller.settings.minimumRecordingDuration = $0 }
                )) {
                    ForEach(AppSettings.minimumRecordingDurations, id: \.self) { duration in
                        Text(Self.recordingDurationLabels[duration] ?? "\(duration) seconds")
                            .tag(duration)
                    }
                }
                .pickerStyle(.menu)

                Text("Recordings shorter than this are deleted without saving audio or a transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transcript") {
                Toggle("Live transcript", isOn: Binding(
                    get: { controller.settings.liveTranscriptEnabled },
                    set: { controller.setLiveTranscriptEnabled($0) }
                ))

                Toggle("Update transcript while people are speaking", isOn: Binding(
                    get: { controller.settings.realtimeTranscriptEnabled },
                    set: { controller.settings.realtimeTranscriptEnabled = $0 }
                ))
                .disabled(!controller.settings.liveTranscriptEnabled)

                Text("Recognizes the active phrase every two seconds and replaces the preview with a final result after a pause. Uses more processing power and takes effect when the next recording starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Show the floating panel on start", isOn: Binding(
                    get: { controller.settings.showPanelOnStart },
                    set: { controller.settings.showPanelOnStart = $0 }
                ))
                .disabled(!controller.settings.liveTranscriptEnabled)

                Toggle("Filter out speaker leakage before recognition", isOn: Binding(
                    get: { controller.settings.echoGateEnabled },
                    set: { controller.settings.echoGateEnabled = $0 }
                ))

                Text("Compares each microphone phrase against the system audio and skips the ones that are only playback leaking back in. A phrase waits up to half a second for the system track before it is recognized; turn this off to send the microphone straight to recognition. Takes effect when the next recording starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Remove duplicate transcript lines", isOn: Binding(
                    get: { controller.settings.transcriptDeduplicationEnabled },
                    set: { controller.settings.transcriptDeduplicationEnabled = $0 }
                ))

                Text("Removes near-simultaneous matching lines captured from both microphone and system audio. Takes effect when the next recording starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Language", selection: Binding(
                    get: { controller.settings.language },
                    set: { controller.settings.language = $0 }
                )) {
                    ForEach(AppSettings.Language.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }

                Picker("Model", selection: Binding(
                    get: { controller.settings.model },
                    set: { controller.selectModel($0) }
                )) {
                    ForEach(AppSettings.availableModels, id: \.id) { model in
                        Text(model.name).tag(model.id)
                    }
                }

                LabeledContent("Model files") { modelControl }

                Text("Downloaded models are prepared in the background when the app starts, so speech recognition is ready before a meeting begins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shortcuts") {
                LabeledContent("Start/stop recording", value: "⌥⌘R")
                LabeledContent("Show/hide the panel", value: "⌥⌘T")
            }

            Section("Permissions") {
                LabeledContent("Microphone") {
                    permissionControl(granted: controller.microphoneGranted) {
                        controller.requestMicrophonePermission()
                    }
                }
                LabeledContent("System audio") {
                    permissionControl(granted: controller.systemAudioPermission == .authorized) {
                        controller.requestSystemAudioPermission()
                    }
                }
                LabeledContent("Accessibility") {
                    permissionControl(granted: controller.accessibilityGranted) {
                        controller.requestAccessibilityPermission()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear {
            controller.refreshPermissions()
            controller.refreshModelState()
        }
    }

    @ViewBuilder
    private var modelControl: some View {
        switch controller.modelState {
        case .missing:
            Button("Download") { controller.downloadModel() }
        case .downloading(let progress):
            HStack(spacing: 8) {
                if let progress {
                    ProgressView(value: progress).frame(width: 120)
                    Text(progress.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Starting download…").foregroundStyle(.secondary)
                }
            }
        case .preparing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing…").foregroundStyle(.secondary)
            }
        case .installed:
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .failed(let message):
            HStack(spacing: 8) {
                Text(message)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                Button("Retry") { controller.downloadModel() }
            }
        }
    }

    @ViewBuilder
    private func permissionControl(granted: Bool, handler: @escaping () -> Void) -> some View {
        if granted {
            Label("Granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        } else {
            Button("Grant", action: handler)
        }
    }
}
