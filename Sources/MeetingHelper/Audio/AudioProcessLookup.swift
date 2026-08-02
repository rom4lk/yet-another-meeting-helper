import AudioToolbox
import Foundation

/// Finds Core Audio process objects belonging to an app family.
///
/// Matching is done on a bundle identifier *prefix* on purpose: a browser plays its audio from
/// helper processes (`com.google.Chrome.helper`) and Zoom spreads audio across `us.zoom.xos`
/// and its meeting helpers, so tapping only the main bundle identifier would miss the audio.
enum AudioProcessLookup {
    struct Match {
        let objectID: AudioObjectID
        let bundleID: String
        let pid: pid_t
    }

    static func matches(prefixes: [String]) -> [Match] {
        guard let objectIDs = try? AudioObjectID.readProcessList() else { return [] }

        return objectIDs.compactMap { objectID in
            guard let bundleID = objectID.processBundleID,
                  prefixes.contains(where: { bundleID == $0 || bundleID.hasPrefix($0 + ".") }),
                  let pid = objectID.processPID
            else { return nil }

            return Match(objectID: objectID, bundleID: bundleID, pid: pid)
        }
    }

    /// `true` when any process of the family holds the microphone. This is the signal that
    /// tells "a browser tab is in a call" apart from "a browser tab is playing a video".
    static func isCapturingInput(prefixes: [String]) -> Bool {
        matches(prefixes: prefixes).contains { $0.objectID.isRunningInput }
    }
}
