import Foundation

/// Removes acoustic-echo transcript lines that were recognized on both capture tracks.
///
/// System audio is the preferred copy because it has not passed through the room and microphone.
/// Same-source repetitions are always preserved.
enum TranscriptDeduplicator {
    private static let maximumOffsetDifference: TimeInterval = 5
    private static let maximumExactShortOffsetDifference: TimeInterval = 2
    private static let maximumContainedPhraseOffsetDifference: TimeInterval = 3

    static func insert(_ line: TranscriptLine, into lines: inout [TranscriptLine]) {
        let matchingIndices = lines.indices.filter { index in
            isDuplicate(line, lines[index])
        }

        guard !matchingIndices.isEmpty else {
            lines.append(line)
            return
        }

        if line.source == .others {
            for index in matchingIndices.reversed() where lines[index].source == .me {
                lines.remove(at: index)
            }
            lines.append(line)
        }
    }

    static func isDuplicate(_ lhs: TranscriptLine, _ rhs: TranscriptLine) -> Bool {
        guard lhs.source != rhs.source else { return false }

        let offsetDifference = abs(lhs.offset - rhs.offset)
        guard offsetDifference <= maximumOffsetDifference else { return false }

        let leftTokens = tokens(in: lhs.text)
        let rightTokens = tokens(in: rhs.text)
        guard !leftTokens.isEmpty, !rightTokens.isEmpty else { return false }

        let left = leftTokens.joined(separator: " ")
        let right = rightTokens.joined(separator: " ")

        if left == right {
            return left.count >= 8 && offsetDifference <= maximumExactShortOffsetDifference
        }

        let shorterTokens = leftTokens.count <= rightTokens.count ? leftTokens : rightTokens
        let longerTokens = leftTokens.count <= rightTokens.count ? rightTokens : leftTokens
        if offsetDifference <= maximumContainedPhraseOffsetDifference,
           shorterTokens.count >= 2,
           shorterTokens.joined(separator: " ").count >= 8,
           longerTokens.count >= shorterTokens.count + 2,
           containsContiguous(shorterTokens, in: longerTokens) {
            return true
        }

        guard left.count >= 12, right.count >= 12 else { return false }
        guard leftTokens.count >= 3, rightTokens.count >= 3 else { return false }

        return editSimilarity(left, right) >= 0.72
            || tokenOverlap(leftTokens, rightTokens) >= 0.8
    }

    private static func tokens(in text: String) -> [String] {
        let normalizedScalars = text.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        return String(normalizedScalars).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func editSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Array(lhs)
        let right = Array(rhs)
        let longestCount = max(left.count, right.count)
        guard longestCount > 0 else { return 1 }

        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            current.reserveCapacity(right.count + 1)

            for (rightIndex, rightCharacter) in right.enumerated() {
                let insertion = current[rightIndex] + 1
                let deletion = previous[rightIndex + 1] + 1
                let substitution = previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                current.append(min(insertion, min(deletion, substitution)))
            }
            previous = current
        }

        return 1 - Double(previous[right.count]) / Double(longestCount)
    }

    private static func tokenOverlap(_ lhs: [String], _ rhs: [String]) -> Double {
        var remaining = rhs.reduce(into: [String: Int]()) { counts, token in
            counts[token, default: 0] += 1
        }
        var matches = 0

        for token in lhs where remaining[token, default: 0] > 0 {
            matches += 1
            remaining[token, default: 0] -= 1
        }

        return Double(matches) / Double(min(lhs.count, rhs.count))
    }

    private static func containsContiguous(_ phrase: [String], in tokens: [String]) -> Bool {
        guard phrase.count <= tokens.count else { return false }
        for start in 0...(tokens.count - phrase.count) {
            if Array(tokens[start..<(start + phrase.count)]) == phrase {
                return true
            }
        }
        return false
    }
}
