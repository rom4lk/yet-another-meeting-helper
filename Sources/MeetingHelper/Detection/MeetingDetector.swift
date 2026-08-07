import AppKit
import Combine
import Foundation

struct DetectedMeeting: Equatable {
    enum Kind: String, Codable {
        case zoom
        case googleMeet
        case ktalk
        case manual

        var displayName: String {
            switch self {
            case .zoom: return "Zoom"
            case .googleMeet: return "Google Meet"
            case .ktalk: return "Ktalk"
            case .manual: return "Manual"
            }
        }

        /// Kinds that live in a browser tab and share the browser detection path.
        var isBrowserMeeting: Bool {
            self == .googleMeet || self == .ktalk
        }
    }

    let kind: Kind
    let title: String
    /// Bundle identifier prefixes whose audio output belongs to this meeting.
    let audioPrefixes: [String]
    let detectedAt: Date

    var capturesAllSystemAudio: Bool {
        kind == .manual
    }

    var audioSourceDisplayName: String {
        guard !capturesAllSystemAudio else { return "All system audio" }

        let apps = [MeetingApp.zoom] + MeetingApp.browsers
        return apps.first { $0.audioBundleIDPrefixes == audioPrefixes }?.displayName
            ?? kind.displayName
    }
}

/// A conferencing service that runs inside a browser tab.
///
/// Such a service has no process of its own, so it is recognised by the title of the browser
/// window, or — for an installed PWA window, which exposes no title — by the host its bundle was
/// created from.
struct BrowserMeetingService {
    let kind: DetectedMeeting.Kind
    /// Matched against a raw window title, browser name suffix included.
    let matchesTitle: (String) -> Bool
    /// Host recorded in the PWA bundle. Subdomains match too: Ktalk gives every organisation its
    /// own one, and Meet is reached through a single host that has none in use.
    let pwaHost: String

    static let all: [BrowserMeetingService] = [
        BrowserMeetingService(
            kind: .googleMeet,
            matchesTitle: MeetingDetector.looksLikeGoogleMeet,
            pwaHost: "meet.google.com"
        ),
        BrowserMeetingService(
            kind: .ktalk,
            matchesTitle: MeetingDetector.looksLikeKtalk,
            pwaHost: "ktalk.ru"
        )
    ]

    func matches(pwaHost host: String) -> Bool {
        host.localizedCaseInsensitiveCompare(pwaHost) == .orderedSame
            || host.lowercased().hasSuffix("." + pwaHost.lowercased())
    }
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
/// holding the microphone, and a window that one of the `BrowserMeetingService` entries claims.
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
            audioPrefixes: [],
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
        guard current == nil || current?.kind.isBrowserMeeting == true else { return }

        var detected: DetectedMeeting?

        search: for browser in MeetingApp.browsers {
            guard AudioProcessLookup.isCapturingInput(prefixes: browser.audioBundleIDPrefixes) else { continue }

            for app in browser.runningApplications {
                for service in BrowserMeetingService.all {
                    guard let title = meetingTitle(for: app, service: service) else { continue }

                    detected = DetectedMeeting(
                        kind: service.kind,
                        title: Self.cleanMeetTitle(title),
                        audioPrefixes: browser.audioBundleIDPrefixes,
                        detectedAt: Date()
                    )
                    break search
                }
            }
        }

        if let detected {
            browserNegativeTicks = 0
            browserPositiveTicks += 1
            if current == nil, browserPositiveTicks >= browserStartTicks {
                begin(detected)
            }
        } else {
            browserPositiveTicks = 0
            guard current?.kind.isBrowserMeeting == true else { return }
            browserNegativeTicks += 1
            if browserNegativeTicks >= browserStopTicks {
                end()
            }
        }
    }

    private func meetingTitle(for app: NSRunningApplication, service: BrowserMeetingService) -> String? {
        let titles = WindowTitles.titles(forPID: app.processIdentifier)
        if let title = titles.first(where: service.matchesTitle) {
            return title
        }

        // Chrome PWA windows expose neither AXTitle nor AXDocument. Their bundle records the
        // installed app URL, so use that as the identity signal while AX confirms a real window.
        guard current?.kind == service.kind || app.isActive else { return nil }
        guard WindowTitles.hasWindows(forPID: app.processIdentifier) else { return nil }
        guard let bundleURL = app.bundleURL,
              let shortcutURL = Bundle(url: bundleURL)?.object(forInfoDictionaryKey: "CrAppModeShortcutURL") as? String,
              let host = URL(string: shortcutURL)?.host,
              service.matches(pwaHost: host)
        else { return nil }

        return app.localizedName ?? service.kind.displayName
    }

    /// Google Meet window titles look like `Meet — abc-defg-hij` or `<name> - Google Meet`.
    static func looksLikeGoogleMeet(_ title: String) -> Bool {
        if title.localizedCaseInsensitiveContains("Google Meet") { return true }
        guard title.localizedCaseInsensitiveContains("Meet") else { return false }
        return title.range(of: "[a-z]{3}-[a-z]{4}-[a-z]{3}", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The Ktalk web client builds every document title as either its own app name alone or
    /// `<page> — <app name>`, and it ships that name untranslated in all of its locales, so the
    /// name is the only stable marker a title carries. It is a string read from a page and matched
    /// against, not interface text — it must stay as the client emits it.
    ///
    /// The name is anchored to the end of the title rather than searched for anywhere in it: as a
    /// bare substring it also occurs inside unrelated Russian words, and an unrelated tab could
    /// then claim a browser that holds the microphone for a real meeting.
    static func looksLikeKtalk(_ title: String) -> Bool {
        let cleaned = cleanMeetTitle(title)
        if cleaned.localizedCaseInsensitiveCompare(ktalkAppName) == .orderedSame { return true }
        return titleSeparators.contains { cleaned.hasSuffix(" \($0) \(ktalkAppName)") }
    }

    private static let ktalkAppName = "Толк"

    /// Separators seen between a title and the name appended after it. Which one appears varies by
    /// browser, by macOS version and — for Ktalk — by what the web client itself emits.
    private static let titleSeparators = ["-", "—", "–"]

    /// Browsers append their own name to the window title; strip it so the meeting keeps the
    /// tab's name.
    ///
    /// The separator differs per browser and per macOS version, and some titles carry invisible
    /// characters — Edge has been seen emitting a zero-width space inside its own name — so the
    /// title is normalised before matching rather than compared against handwritten literals.
    static func cleanMeetTitle(_ title: String) -> String {
        let normalized = title.unicodeScalars
            .filter { !Self.invisibleScalars.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }

        for name in MeetingApp.browsers.map(\.displayName) {
            for separator in titleSeparators {
                let suffix = " \(separator) \(name)"
                if normalized.hasSuffix(suffix) {
                    return String(normalized.dropLast(suffix.count))
                        .trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return normalized.trimmingCharacters(in: .whitespaces)
    }

    /// Zero-width space, non-joiner, joiner and BOM: present in real window titles, invisible in
    /// source, and enough to break a literal comparison.
    private static let invisibleScalars: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}"]

    // MARK: - Transitions

    private func begin(_ meeting: DetectedMeeting) {
        guard current == nil else { return }
        current = meeting
        browserPositiveTicks = 0
        browserNegativeTicks = 0
        // The kind stays public so a missed meeting can still be debugged from `log show`; the
        // title is user data and must not be written to the system log in the clear.
        Log.detection.notice("Meeting started: \(meeting.kind.rawValue, privacy: .public) — \(meeting.title, privacy: .private)")
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
