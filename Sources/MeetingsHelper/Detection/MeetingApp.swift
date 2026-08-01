import AppKit
import Foundation

/// An app whose audio we may need to capture.
///
/// `audioBundleIDPrefixes` is deliberately broader than the main bundle identifier: conferencing
/// apps and browsers push their audio through helper processes that have their own identifiers.
struct MeetingApp: Identifiable, Hashable {
    let id: String
    let displayName: String
    let mainBundleID: String
    let audioBundleIDPrefixes: [String]
    let isBrowser: Bool

    static let zoom = MeetingApp(
        id: "zoom",
        displayName: "Zoom",
        mainBundleID: "us.zoom.xos",
        audioBundleIDPrefixes: ["us.zoom"],
        isBrowser: false
    )

    static let chrome = MeetingApp(
        id: "chrome",
        displayName: "Google Chrome",
        mainBundleID: "com.google.Chrome",
        audioBundleIDPrefixes: ["com.google.Chrome"],
        isBrowser: true
    )

    static let arc = MeetingApp(
        id: "arc",
        displayName: "Arc",
        mainBundleID: "company.thebrowser.Browser",
        audioBundleIDPrefixes: ["company.thebrowser"],
        isBrowser: true
    )

    static let edge = MeetingApp(
        id: "edge",
        displayName: "Microsoft Edge",
        mainBundleID: "com.microsoft.edgemac",
        audioBundleIDPrefixes: ["com.microsoft.edgemac"],
        isBrowser: true
    )

    static let safari = MeetingApp(
        id: "safari",
        displayName: "Safari",
        mainBundleID: "com.apple.Safari",
        audioBundleIDPrefixes: ["com.apple.Safari", "com.apple.WebKit"],
        isBrowser: true
    )

    static let browsers: [MeetingApp] = [.chrome, .arc, .edge, .safari]

    var runningApplications: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { application in
            guard let bundleID = application.bundleIdentifier else { return false }
            return bundleID == mainBundleID || bundleID.hasPrefix(mainBundleID + ".")
        }
    }
}
