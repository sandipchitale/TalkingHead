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

    /// How much of the lift applies at `x`: 0 at the edges, 1 across the middle. `taper` is the
    /// fraction of the width at each end over which it fades.
    func weight(atX x: Double, taper: Double = 0.3) -> Double {
        let u = (x - minX) / (maxX - minX)
        guard u > 0, u < 1 else { return 0 }
        let edge = min(u, 1 - u) / taper
        guard edge < 1 else { return 1 }
        return edge * edge * (3 - 2 * edge)
    }

    /// How much of a tilt applies at `x`: nothing at the outer end, rising to 1 near the inner
    /// end (the one nearer `centerX`, the middle of the face).
    func tiltWeight(atX x: Double, centerX: Double) -> Double {
        let u = (x - minX) / (maxX - minX)
        let inner = (minX + maxX) / 2 < centerX ? u : 1 - u
        return max(0, inner) * weight(atX: x, taper: 0.1)
    }
}

/// When the eyebrows move while speaking.
nonisolated enum Emphasis {
    /// How high the eyebrows go at the end of a question or exclamation.
    static let exclaimedLift = 1.5

    /// Where the eyebrows go for the word at `range` in `text`: positive raises them, negative
    /// lowers them a little, and nil leaves them be.
    ///
    /// The last word before "?" or "!" raises them highest (`exclaimedLift`). Otherwise
    /// negative or doubtful words ("not", "never", "but", "sorry"…) lower them, and words in
    /// capitals raise them. Other words raise them when the voice stresses them: `accent`
    /// (0 ... 1) is how much the word's pitch rises (see `WordProsody`). When that isn't known,
    /// the stress is guessed from the text instead (see `raisesBrows`).
    static func brows(for range: NSRange, in text: String, accent: Double? = nil) -> Double? {
        let nsText = text as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= nsText.length else { return nil }
        if endsQuestionOrExclamation(range, in: nsText) { return exclaimedLift }
        let word = nsText.substring(with: range)
        if lowersBrows(word) { return -0.5 }
        if isShouted(word) { return 1 }
        if let accent {
            return accent >= 0.2 ? 0.6 + 0.4 * accent : nil
        }
        return raisesBrows(range, in: text) ? 1 : nil
    }

    /// Whether `word` is in capitals, like "NOT" (a single capital, like "I", doesn't count).
    private static func isShouted(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        return letters.count >= 2 && letters.allSatisfy(\.isUppercase)
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
        if isShouted(word) {
            return true
        }
        if letters.count >= 7 {
            return true
        }
        return endsQuestionOrExclamation(range, in: text)
    }

    private static let quotes: Set<Character> = ["\"", "'", "“", "”", "‘", "’"]
}
