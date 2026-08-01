import SwiftUI

struct SettingsView: View {
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

            Section("Transcript") {
                Toggle("Live transcript", isOn: Binding(
                    get: { controller.settings.liveTranscriptEnabled },
                    set: { controller.settings.liveTranscriptEnabled = $0 }
                ))

                Toggle("Show the floating panel on start", isOn: Binding(
                    get: { controller.settings.showPanelOnStart },
                    set: { controller.settings.showPanelOnStart = $0 }
                ))
                .disabled(!controller.settings.liveTranscriptEnabled)

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

                Text("Otherwise the model downloads itself during the first recording — and the opening minutes of the meeting stay untranscribed.")
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
                if let progress, progress < 1 {
                    ProgressView(value: progress).frame(width: 120)
                    Text(progress.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Loading into memory…").foregroundStyle(.secondary)
                }
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
