import Foundation

/// What the gate concluded about one microphone utterance.
enum EchoVerdict {
    /// Speaker leakage: it repeats the system envelope and sits far below it.
    case echo
    /// Compared against the system track and kept.
    case speech
    /// Nothing usable to compare against, so the utterance is kept without a check.
    case undecided
}

/// Decides whether a microphone utterance is speaker playback leaking back in rather than speech.
///
/// Echo repeats the shape of the system track's loudness envelope, delayed by the acoustic path
/// and heavily attenuated by it. Two conditions have to hold together before an utterance is
/// dropped: the envelopes must correlate, and the microphone must be far quieter than the source.
/// Real speech that overlaps playback fails the level test by a wide margin even when it happens
/// to correlate, which is what keeps interjections in the transcript.
///
/// Thresholds are measured, not guessed — see `knowledge/echo-gate-calibration.md`.
enum EchoGate {
    /// Acoustic delay to search, 0…500 ms. Measured recordings peak at lag 0, but Bluetooth
    /// output adds latency and the search costs a few hundred multiplications.
    static let maximumLagFrames = 5
    /// Shorter windows do not carry enough shape for a correlation to mean anything.
    static let minimumFrames = 5
    static let minimumCorrelation = 0.8
    /// Decibels, microphone relative to the reference. Echo measured at −19 dB and below,
    /// speech over playback at −13 dB and above.
    static let maximumLevelDifference: Float = -18
    /// Decibels. Below this the reference is silence and there is nothing to have leaked.
    static let minimumReferenceLevel: Float = -50

    /// `microphone` is the utterance's per-frame loudness; `reference` covers the same span
    /// extended by `maximumLagFrames` at the front, so every lag can be tried.
    static func isEcho(microphone: [Float], reference: [Float]) -> Bool {
        guard microphone.count >= minimumFrames,
              reference.count == microphone.count + maximumLagFrames
        else { return false }

        for lag in 0...maximumLagFrames {
            let start = maximumLagFrames - lag
            let candidate = Array(reference[start..<(start + microphone.count)])

            guard decibels(rms(candidate)) >= minimumReferenceLevel,
                  decibels(rms(microphone)) - decibels(rms(candidate)) <= maximumLevelDifference
            else { continue }

            if correlation(microphone, candidate) >= minimumCorrelation { return true }
        }

        return false
    }

    /// Pearson correlation of the two envelopes: how alike their shapes are, regardless of level.
    static func correlation(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, lhs.count >= minimumFrames else { return 0 }

        let count = Double(lhs.count)
        let leftMean = lhs.reduce(0) { $0 + Double($1) } / count
        let rightMean = rhs.reduce(0) { $0 + Double($1) } / count

        var covariance = 0.0
        var leftVariance = 0.0
        var rightVariance = 0.0
        for index in lhs.indices {
            let left = Double(lhs[index]) - leftMean
            let right = Double(rhs[index]) - rightMean
            covariance += left * right
            leftVariance += left * left
            rightVariance += right * right
        }

        guard leftVariance > 0, rightVariance > 0 else { return 0 }
        return covariance / (leftVariance * rightVariance).squareRoot()
    }

    private static func rms(_ levels: [Float]) -> Float {
        guard !levels.isEmpty else { return 0 }
        var sum: Float = 0
        for level in levels { sum += level * level }
        return (sum / Float(levels.count)).squareRoot()
    }

    private static func decibels(_ value: Float) -> Float {
        20 * log10(max(value, 1e-6))
    }
}
