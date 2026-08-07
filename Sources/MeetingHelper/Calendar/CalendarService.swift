import AppKit
import EventKit
import Foundation

/// Reads the calendars macOS already syncs.
///
/// Meeting Helper never talks to Google itself. The account is added once in System Settings,
/// where macOS signs in with its own credentials, and every calendar it syncs afterwards — work,
/// personal, iCloud — is readable through EventKit. That keeps the app free of an OAuth client, a
/// client secret and a Google Cloud project, and leaves the sign-in with the system that already
/// owns it.
@MainActor
final class CalendarService: ObservableObject {
    enum Access: Equatable {
        case notDetermined
        case granted
        /// Refused, or limited to writing, or blocked by a device policy. Only System Settings can
        /// change it — asking again does nothing.
        case denied
    }

    @Published private(set) var access: Access
    /// The accounts macOS syncs event calendars from, named as System Settings names them. Shown
    /// in the settings screen because it is the only way to tell that both calendars arrived.
    @Published private(set) var accountTitles: [String] = []

    /// How far around the present to look. Backwards far enough to still find a call that started
    /// before the recording did, forwards far enough for one that is about to begin.
    private static let windowBefore: TimeInterval = 60 * 60
    private static let windowAfter: TimeInterval = 3 * 60 * 60

    private let store = EKEventStore()
    private var changeObserver: NSObjectProtocol?

    init() {
        access = Self.access(for: EKEventStore.authorizationStatus(for: .event))
    }

    var isEnabled: Bool { access == .granted }

    // MARK: - Lifecycle

    func bootstrap() {
        guard changeObserver == nil else { return }

        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    /// Access is granted in a system alert and accounts are added in System Settings, neither of
    /// which reports back. Coming back to the app is the moment to look again.
    func applicationDidBecomeActive() {
        access = Self.access(for: EKEventStore.authorizationStatus(for: .event))
        reload()
    }

    // MARK: - Access

    func requestAccess() async {
        guard access == .notDetermined else { return }

        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            Log.calendar.error("Calendar access request failed: \(error.localizedDescription, privacy: .public)")
        }
        access = Self.access(for: EKEventStore.authorizationStatus(for: .event))
        reload()
    }

    /// Where the user grants access after having refused it once.
    static func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
        NSWorkspace.shared.open(url)
    }

    /// Where Google accounts are added, and where macOS performs the sign-in.
    static func openAccountSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Matching

    /// The calendar event a starting recording belongs to.
    ///
    /// EventKit reads a local database, so this is a plain query rather than a cache kept warm in
    /// the background: there is no round trip worth avoiding and no window that can go stale.
    func bestMatch(for meeting: DetectedMeeting) -> CalendarEventMatcher.Match? {
        guard isEnabled else { return nil }
        return CalendarEventMatcher.bestMatch(for: meeting, in: events(around: meeting.detectedAt))
    }

    private func events(around moment: Date) -> [CalendarEvent] {
        let predicate = store.predicateForEvents(
            withStart: moment.addingTimeInterval(-Self.windowBefore),
            end: moment.addingTimeInterval(Self.windowAfter),
            calendars: nil
        )

        return store.events(matching: predicate).compactMap(CalendarEvent.init)
    }

    // MARK: - Accounts

    private func reload() {
        guard isEnabled else {
            accountTitles = []
            return
        }

        // EventKit holds its sources until it is told to look again, so an account added while the
        // app was running stays invisible without this.
        store.reset()
        accountTitles = Set(store.calendars(for: .event).map(\.source.title)).sorted()
    }

    private static func access(for status: EKAuthorizationStatus) -> Access {
        switch status {
        case .notDetermined: return .notDetermined
        case .fullAccess: return .granted
        default: return .denied
        }
    }
}
