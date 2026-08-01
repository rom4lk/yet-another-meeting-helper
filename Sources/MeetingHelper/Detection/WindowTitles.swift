import ApplicationServices
import AppKit
import Foundation

/// Reads window titles of other apps through the Accessibility API.
///
/// Used only to give a meeting a human-readable name and to tell a Google Meet tab apart from
/// any other browser tab that happens to hold the microphone. Everything degrades gracefully
/// when the permission is missing — detection still works, the title just becomes generic.
enum WindowTitles {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    static func titles(forPID pid: pid_t) -> [String] {
        windows(forPID: pid).compactMap { window in
            var titleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
                  let title = titleValue as? String,
                  !title.isEmpty
            else { return nil }
            return title
        }
    }

    static func hasWindows(forPID pid: pid_t) -> Bool {
        !windows(forPID: pid).isEmpty
    }

    static func titles(forBundleID bundleID: String) -> [String] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .flatMap { titles(forPID: $0.processIdentifier) }
    }

    private static func windows(forPID pid: pid_t) -> [AXUIElement] {
        guard isTrusted else { return [] }

        let app = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement]
        else { return [] }

        return windows
    }
}
