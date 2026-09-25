import AppKit

/// Loads the text to speak for a URL: the page's visible text or, when the URL has a text
/// fragment (`#:~:text=…`), just the passage it highlights.
enum WebPage {
    enum LoadError: LocalizedError {
        case httpStatus(Int)
        case unsupportedType(String)
        case noText
        case fragmentNotFound

        var errorDescription: String? {
            switch self {
            case .httpStatus(let code): "The page returned HTTP status \(code)."
            case .unsupportedType(let type): "Can't read text from \(type) content."
            case .noText: "The page has no text to speak."
            case .fragmentNotFound: "Couldn't find the highlighted text on the page."
            }
        }
    }

    /// The text to speak for `url`.
    static func speakableText(for url: URL) async throws -> String {
        let page = try await text(at: url)
        guard let fragment = TextFragment(url: url) else { return page }
        guard let passage = fragment.passage(in: page) else { throw LoadError.fragmentNotFound }
        return passage
    }

    /// All the visible text of the page (or file) at `url`.
    static func text(at url: URL) async throws -> String {
        if url.isFileURL {
            return try TextFile.read(url)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LoadError.httpStatus(http.statusCode)
        }
        let mimeType = response.mimeType ?? "text/html"
        let encoding = response.textEncodingName
            .map { String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding($0 as CFString))) }
            ?? .utf8

        let text: String
        if mimeType.contains("html") || mimeType.contains("xml") {
            // AppKit's HTML import must run on the main thread.
            text = try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: encoding.rawValue],
                documentAttributes: nil
            ).string
        } else if mimeType.hasPrefix("text/") {
            text = String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
        } else {
            throw LoadError.unsupportedType(mimeType)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LoadError.noText }
        return text
    }
}
