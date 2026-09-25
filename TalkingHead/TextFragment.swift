import Foundation

/// A text fragment directive from a URL (`#:~:text=[prefix-,]start[,end][,-suffix]`), as made
/// by Safari's "Copy Link to Highlight", and the logic to find the passage it refers to.
nonisolated struct TextFragment: Equatable, Sendable {
    var prefix: String?
    var start: String
    var end: String?
    var suffix: String?

    init(prefix: String? = nil, start: String, end: String? = nil, suffix: String? = nil) {
        self.prefix = prefix
        self.start = start
        self.end = end
        self.suffix = suffix
    }

    /// The first text directive in `url`'s fragment, or `nil` if it has none.
    init?(url: URL) {
        guard let fragment = url.fragment(percentEncoded: true),
              let delimiter = fragment.range(of: ":~:")
        else { return nil }
        let directives = fragment[delimiter.upperBound...].split(separator: "&")
        guard let directive = directives.first(where: { $0.hasPrefix("text=") }) else { return nil }

        // Commas and dashes inside the text are percent-encoded, so split before decoding.
        var parts = directive.dropFirst("text=".count)
            .split(separator: ",", omittingEmptySubsequences: false)
            .map(String.init)
        func decode(_ part: String) -> String { part.removingPercentEncoding ?? part }

        var prefix: String?
        var suffix: String?
        if parts.count > 1, let first = parts.first, first.hasSuffix("-") {
            prefix = decode(String(first.dropLast()))
            parts.removeFirst()
        }
        if parts.count > 1, let last = parts.last, last.hasPrefix("-") {
            suffix = decode(String(last.dropFirst()))
            parts.removeLast()
        }
        guard (1...2).contains(parts.count), !parts[0].isEmpty else { return nil }
        self.init(prefix: prefix, start: decode(parts[0]), end: parts.count == 2 ? decode(parts[1]) : nil,
                  suffix: suffix)
    }

    /// The passage of `text` this fragment refers to: from `start` through `end` (or just
    /// `start`), preceded by `prefix` and followed by `suffix` when given. Matching ignores
    /// case and treats any run of whitespace as a single space.
    func passage(in text: String) -> String? {
        var pattern = ""
        if let prefix { pattern += Self.words(prefix) + #"\s*"# }
        pattern += "(" + Self.words(start)
        if let end { pattern += #"[\s\S]*?"# + Self.words(end) }
        pattern += ")"
        if let suffix { pattern += #"(?=\s*"# + Self.words(suffix) + ")" }

        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    /// A pattern matching `phrase`'s words literally, with any whitespace between them.
    private static func words(_ phrase: String) -> String {
        phrase.split(whereSeparator: \.isWhitespace)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: #"\s+"#)
    }
}
