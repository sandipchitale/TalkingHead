import Foundation

/// Where one eyebrow is, in image pixels. The brow is raised by stretching the skin between
/// it and the eye and squeezing the forehead above it, so no painted-out patch is needed.
nonisolated struct BrowRegion: Sendable {
    /// Left and right edges; the lift fades to nothing toward them.
    var minX: Double
    var maxX: Double
    /// Forehead above the brow, which stays put.
    var top: Double
    /// The middle of the brow, which moves up by the lift.
    var line: Double
    /// Just above the eye, which stays put.
    var bottom: Double

    /// How much of the lift applies at `x`: 0 at the edges, 1 across the middle.
    func weight(atX x: Double) -> Double {
        let u = (x - minX) / (maxX - minX)
        guard u > 0, u < 1 else { return 0 }
        let edge = min(u, 1 - u) / 0.3
        guard edge < 1 else { return 1 }
        return edge * edge * (3 - 2 * edge)
    }
}

/// When the eyebrows move while speaking.
nonisolated enum Emphasis {
    /// How high the eyebrows go at the end of a question or exclamation.
    static let exclaimedLift = 1.5

    /// Where the eyebrows go for the word at `range` in `text`: 1 raises them, a negative value
    /// lowers them a little, and nil leaves them be. The last word before "?" or "!" raises
    /// them higher (`exclaimedLift`); otherwise negative or doubtful words ("not", "never",
    /// "but", "sorry"…) lower them, and other stressed words raise them (see `raisesBrows`).
    static func brows(for range: NSRange, in text: String) -> Double? {
        let nsText = text as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= nsText.length else { return nil }
        if endsQuestionOrExclamation(range, in: nsText) { return exclaimedLift }
        if lowersBrows(nsText.substring(with: range)) { return -0.5 }
        return raisesBrows(range, in: text) ? 1 : nil
    }

    /// Whether the word at `range` is the last before "?" or "!".
    private static func endsQuestionOrExclamation(_ range: NSRange, in text: NSString) -> Bool {
        let word = text.substring(with: range)
        let next = text.substring(from: NSMaxRange(range)).first { !$0.isWhitespace && !quotes.contains($0) }
        return next == "?" || next == "!" || word.contains("?") || word.contains("!")
    }

    /// Whether `word` is negative or doubtful: "not", "never", "can't", "but", "sorry"…
    static func lowersBrows(_ word: String) -> Bool {
        let word = word.lowercased().filter { $0.isLetter || $0 == "'" || $0 == "’" }
        return word.hasSuffix("n't") || word.hasSuffix("n’t") || lowering.contains(word)
    }

    private static let lowering: Set<String> = [
        "no", "not", "never", "nothing", "nobody", "none", "nor", "neither", "cannot",
        "but", "however", "although", "though", "unfortunately", "sadly", "sorry",
        "problem", "problems", "wrong", "error", "errors", "fail", "failed", "failure",
        "careful", "warning", "worry", "worried", "difficult", "serious", "bad", "hmm",
    ]

    /// Whether the word at `range` in `text` is stressed enough to raise the eyebrows: the
    /// first word of a sentence or clause, a word in capitals, a long word, or the last word
    /// before "?" or "!".
    static func raisesBrows(_ range: NSRange, in text: String) -> Bool {
        let text = text as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { return false }
        let word = text.substring(with: range)
        let letters = word.filter(\.isLetter)

        // The last character before the word, other than spaces and quotes.
        let before = text.substring(to: range.location).last { !$0.isWhitespace && !Self.quotes.contains($0) }
        if before == nil || ".!?,;:—".contains(before!) {
            return true
        }
        if letters.count >= 2, letters.allSatisfy(\.isUppercase) {
            return true
        }
        if letters.count >= 7 {
            return true
        }
        return endsQuestionOrExclamation(range, in: text)
    }

    private static let quotes: Set<Character> = ["\"", "'", "“", "”", "‘", "’"]
}
