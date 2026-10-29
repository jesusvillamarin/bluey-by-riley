import Foundation

/// Cuts a reply that grows delta by delta into sentences he can speak while the rest is still being written.
struct SentenceSplitter {
    private static let terminators: Set<Character> = [".", "!", "?", "…"]
    /// Quotes and brackets that close over a sentence's final mark: `"go!"` is one sentence.
    private static let closers: Set<Character> = ["\"", "”", "’", ")", "]", "»"]

    /// The reply as last accepted, and how many of its characters have already gone out as sentences.
    private var latest = ""
    private var handedOut = 0

    /// Each sentence in `replySoFar` that is complete and not handed out before: it ends in `.`, `!`, `?` or `…`
    /// followed by whitespace. Text that doesn't continue what was already handed out is ignored, so nothing is said twice.
    mutating func feed(_ replySoFar: String) -> [String] {
        guard replySoFar.hasPrefix(String(latest.prefix(handedOut))) else { return [] }
        latest = replySoFar
        var sentences: [String] = []
        var start = latest.index(latest.startIndex, offsetBy: handedOut)
        var index = start
        while index < latest.endIndex {
            guard Self.terminators.contains(latest[index]) else { index = latest.index(after: index); continue }
            var end = latest.index(after: index)
            while end < latest.endIndex, Self.closers.contains(latest[end]) { end = latest.index(after: end) }
            guard end < latest.endIndex, latest[end].isWhitespace else { index = end; continue }
            let sentence = latest[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            start = end
            index = end
        }
        handedOut = latest.distance(from: latest.startIndex, to: start)
        return sentences
    }

    /// What is left after the last sentence (the reply has ended without a closing mark); nil if only whitespace. Once.
    mutating func finish() -> String? {
        let rest = latest.dropFirst(handedOut).trimmingCharacters(in: .whitespacesAndNewlines)
        handedOut = latest.count
        return rest.isEmpty ? nil : rest
    }
}
