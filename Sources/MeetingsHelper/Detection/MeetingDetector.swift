import AppKit
import Combine
import Foundation

struct DetectedMeeting: Equatable {
    enum Kind: String, Codable {
        case zoom
        case googleMeet
        case manual

        var displayName: String {
            switch self {
            case .zoom: return "Zoom"
            case .googleMeet: return "Google Meet"
            case .manual: return "Manual"
            }
        }
    }

    let kind: Kind
    let title: String
    /// Bundle identifier prefixes whose audio output belongs to this meeting.
    let audioPrefixes: [String]
    let detectedAt: Date
}

/// Watches the system for meetings that have actually *started*.
///
/// Zoom is detected by its meeting helper process `us.zoom.CptHost`, which the client spawns on
/// join and kills on leave. That is a far sharper signal than "some app opened the microphone" —
/// it fires the moment the meeting begins, and never fires for the Zoom main window.
///
/// `CptHost` is an agent (`LSUIElement`), and `NSWorkspace` does not post launch or terminate
/// notifications for agents — it only reports them in `runningApplications`. So everything here
/// is driven by one poll.
///
/// Browser meetings have no such process, so there we combine two weaker signals: the browser
/// holding the microphone, and a window title that looks like Google Meet.
@MainActor
final class MeetingDetector: ObservableObject {
    static let zoomMeetingBundleID = "us.zoom.CptHost"

    @Published private(set) var current: DetectedMeeting?
    @Published var autoDetectionEnabled = true {
        didSet { autoDetectionEnabled ? startWatching() : stopWatching() }
    }

    var onStart: ((DetectedMeeting) -> Void)?
    var onStop: (() -> Void)?

    private var pollTimer: Timer?
    private var browserPositiveTicks = 0
    private var browserNegativeTicks = 0

    private let browserStartTicks = 2
    private let browserStopTicks = 3

    func startWatching() {
        guard pollTimer == nil else { return }

        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        poll()
        // `notice` and above is what `log show` keeps on disk, so these three transitions stay
        // visible after the fact — `info` is dropped and cannot be used to debug a missed meeting.
        Log.detection.notice("Detector started")
    }

    func stopWatching() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        pollZoom()
        pollBrowsers()
    }

    /// Called when the user starts a recording by hand or via the global hotkey.
    func beginManual(title: String) {
        guard current == nil else { return }
        begin(DetectedMeeting(
            kind: .manual,
            title: title,
            audioPrefixes: MeetingApp.manualFallbackPrefixes,
            detectedAt: Date()
        ))
    }

    /// Called when the user stops a recording by hand — clears the state so a later automatic
    /// detection can fire again.
    func clearCurrent() {
        guard current != nil else { return }
        current = nil
        browserPositiveTicks = 0
        browserNegativeTicks = 0
    }

    // MARK: - Zoom

    private var isZoomMeetingRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.zoomMeetingBundleID).isEmpty
    }

    private func pollZoom() {
        if isZoomMeetingRunning {
            guard current == nil else { return }
            begin(zoomMeeting())
        } else {
            guard current?.kind == .zoom else { return }
            end()
        }
    }

    private func zoomMeeting() -> DetectedMeeting {
        DetectedMeeting(
            kind: .zoom,
            title: zoomTitle() ?? "Zoom meeting",
            audioPrefixes: MeetingApp.zoom.audioBundleIDPrefixes,
            detectedAt: Date()
        )
    }

    private func zoomTitle() -> String? {
        let ignored: Set<String> = ["Zoom", "Zoom Workplace", "zoom.us"]
        let titles = WindowTitles.titles(forBundleID: MeetingApp.zoom.mainBundleID)
            + WindowTitles.titles(forBundleID: Self.zoomMeetingBundleID)

        return titles.first { !ignored.contains($0) && !$0.hasPrefix("Zoom Workplace —") }
    }

    // MARK: - Browser meetings

    private func pollBrowsers() {
        guard current == nil || current?.kind == .googleMeet else { return }

        var detected: DetectedMeeting?

        for browser in MeetingApp.browsers {
            guard AudioProcessLookup.isCapturingInput(prefixes: browser.audioBundleIDPrefixes) else { continue }

            for app in browser.runningApplications {
                guard let title = googleMeetTitle(for: app) else { continue }

                detected = DetectedMeeting(
                    kind: .googleMeet,
                    title: Self.cleanMeetTitle(title),
                    audioPrefixes: browser.audioBundleIDPrefixes,
                    detectedAt: Date()
                )
                break
            }

            if detected != nil { break }
        }

        if detected != nil {
            browserNegativeTicks = 0
            browserPositiveTicks += 1
            if current == nil, browserPositiveTicks >= browserStartTicks, let detected {
                begin(detected)
            }
        } else {
            browserPositiveTicks = 0
            guard current?.kind == .googleMeet else { return }
            browserNegativeTicks += 1
            if browserNegativeTicks >= browserStopTicks {
                end()
            }
        }
    }

    private func googleMeetTitle(for app: NSRunningApplication) -> String? {
        let titles = WindowTitles.titles(forPID: app.processIdentifier)
        if let title = titles.first(where: Self.looksLikeGoogleMeet) {
            return title
        }

        // Chrome PWA windows expose neither AXTitle nor AXDocument. Their bundle records the
        // installed app URL, so use that as the identity signal while AX confirms a real window.
        guard current?.kind == .googleMeet || app.isActive else { return nil }
        guard WindowTitles.hasWindows(forPID: app.processIdentifier) else { return nil }
        guard let bundleURL = app.bundleURL,
              let shortcutURL = Bundle(url: bundleURL)?.object(forInfoDictionaryKey: "CrAppModeShortcutURL") as? String,
              URL(string: shortcutURL)?.host?.localizedCaseInsensitiveCompare("meet.google.com") == .orderedSame
        else { return nil }

        return app.localizedName ?? "Google Meet"
    }

    /// Google Meet window titles look like `Meet — abc-defg-hij` or `<name> - Google Meet`.
    private static func looksLikeGoogleMeet(_ title: String) -> Bool {
        if title.localizedCaseInsensitiveContains("Google Meet") { return true }
        guard title.localizedCaseInsensitiveContains("Meet") else { return false }
        return title.range(of: "[a-z]{3}-[a-z]{4}-[a-z]{3}", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func cleanMeetTitle(_ title: String) -> String {
        var cleaned = title
        for suffix in [" - Google Chrome", " — Google Chrome", " - Safari", " — Arc", " - Microsoft​ Edge"] {
            if cleaned.hasSuffix(suffix) {
                cleaned.removeLast(suffix.count)
            }
        }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Transitions

    private func begin(_ meeting: DetectedMeeting) {
        guard current == nil else { return }
        current = meeting
        browserPositiveTicks = 0
        browserNegativeTicks = 0
        Log.detection.notice("Meeting started: \(meeting.kind.rawValue, privacy: .public) — \(meeting.title, privacy: .public)")
        onStart?(meeting)
    }

    private func end() {
        guard current != nil else { return }
        current = nil
        browserPositiveTicks = 0
        browserNegativeTicks = 0
        Log.detection.notice("Meeting ended")
        onStop?()
    }
}
