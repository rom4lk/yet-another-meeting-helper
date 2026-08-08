import SwiftUI

@MainActor
protocol ApplicationTerminationControlling: AnyObject {
    var isRecording: Bool { get }
    var isStopping: Bool { get }
    func requestStop(startsPendingMeeting: Bool, completion: @escaping () -> Void)
}

extension AppController: ApplicationTerminationControlling {
    func requestStop(startsPendingMeeting: Bool, completion: @escaping () -> Void) {
        stopRecording(startsPendingMeeting: startsPendingMeeting, completion: completion)
    }
}

@MainActor
enum ApplicationTerminationHandler {
    static func reply(
        for controller: (any ApplicationTerminationControlling)?,
        afterStopping: @escaping () -> Void
    ) -> NSApplication.TerminateReply {
        guard let controller, controller.isRecording || controller.isStopping else {
            return .terminateNow
        }

        controller.requestStop(startsPendingMeeting: false, completion: afterStopping)
        return .terminateLater
    }
}

@main
struct MeetingHelperApp: App {
    @StateObject private var controller = AppController()
    @Environment(\.scenePhase) private var scenePhase
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Meetings", id: "main") {
            RootView()
                .environmentObject(controller)
                .frame(minWidth: 860, minHeight: 520)
                .onAppear {
                    appDelegate.controller = controller
                    controller.bootstrap()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        controller.applicationDidBecomeActive()
                    }
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button(controller.isRecording ? "Stop Recording" : "Start Recording") {
                    controller.toggleRecording()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])

                Button("Floating Panel") {
                    controller.togglePanel()
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
            }
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(controller)
        } label: {
            Image(systemName: controller.isRecording ? "record.circle.fill" : "waveform")
        }

        Settings {
            SettingsView()
                .environmentObject(controller)
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ApplicationTerminationHandler.reply(for: controller) {
            sender.reply(toApplicationShouldTerminate: true)
        }
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let session = controller.session {
            Text("Recording: \(session.title)")
            Text(session.elapsed.clockString)
            Text("Microphone: \(session.microphoneDeviceName)")
            Button("Stop Recording") { controller.stopRecording() }
        } else {
            Button("Start Recording") { controller.startManualRecording() }
        }

        Button(controller.isPanelVisible ? "Hide Transcript Panel" : "Show Transcript Panel") {
            controller.togglePanel()
        }

        Divider()

        Button("Open Meetings Window") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Quit") { NSApp.terminate(nil) }
    }
}
