import AppKit
import AudioToolbox
import Foundation

/// System audio recording permission (`kTCCServiceAudioCapture`).
///
/// There is no public API for this one, and the obvious probes do not work: Core Audio hands
/// out process bundle identifiers without the permission, and `AudioHardwareCreateProcessTap`
/// returns `noErr` when denied — it just delivers silence. So we go through the same TCC SPI
/// that AudioCap and other system-audio apps use, and degrade to `.unknown` if it ever
/// disappears. `RecordingSession` independently notices a silent tap at runtime, so a wrong
/// answer here is a cosmetic problem rather than a silent failure.
enum SystemAudioPermission {
    enum Status {
        case authorized
        case denied
        case unknown
    }

    nonisolated(unsafe) private static let service = "kTCCServiceAudioCapture" as CFString

    static func status() -> Status {
        guard let preflight = preflightSPI else { return .unknown }
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Raises the system prompt the first time; afterwards the user has to change the decision
    /// in System Settings.
    static func request(completion: @escaping (Status) -> Void) {
        guard let request = requestSPI else {
            // Fallback: creating a tap is what normally triggers the prompt.
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            description.uuid = UUID()
            description.isPrivate = true
            description.muteBehavior = .unmuted
            var tapID = AudioObjectID.unknown
            AudioHardwareCreateProcessTap(description, &tapID)
            if tapID.isValid { AudioHardwareDestroyProcessTap(tapID) }
            completion(status())
            return
        }

        request(service, nil) { granted in
            DispatchQueue.main.async {
                completion(granted ? .authorized : .denied)
            }
        }
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - TCC SPI

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    // Resolved once and never mutated; the handle and symbols stay valid for the process lifetime.
    nonisolated(unsafe) private static let tccHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    }()

    private static let preflightSPI: PreflightFunction? = {
        guard let tccHandle, let symbol = dlsym(tccHandle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: PreflightFunction.self)
    }()

    private static let requestSPI: RequestFunction? = {
        guard let tccHandle, let symbol = dlsym(tccHandle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(symbol, to: RequestFunction.self)
    }()
}
