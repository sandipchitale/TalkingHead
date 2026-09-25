import AppKit

/// Reads the text to speak from a file: plain text in any common encoding, or the text of
/// RTF, HTML, Word and other documents AppKit can read. Used by `th` and the file button.
enum TextFile {
    static func read(_ url: URL) throws -> String {
        try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
    }
}
