import AppKit
import Foundation
import Testing
@testable import TalkingHead

struct VisemeTests {
    @Test(arguments: [
        ("friend", [Viseme.fv, .r, .ee, .consonant]),
        ("mom", [.mbp, .o, .mbp]),
        ("shoe", [.chjsh, .o]),
        ("thought", [.th, .u, .consonant]),
        ("happy", [.ai, .mbp, .ee]),
        ("quick", [.qw, .ai, .consonant]),
        ("pie", [.mbp, .ee]),
    ])
    func sequence(word: String, expected: [Viseme]) {
        #expect(Viseme.sequence(for: word) == expected)
    }

    @Test func punctuationIsIgnored() {
        #expect(Viseme.sequence(for: "pie.") == Viseme.sequence(for: "pie"))
    }

    @Test func wordsWithoutLettersStillMoveTheMouth() {
        #expect(Viseme.sequence(for: "42") == [.ai])
    }

    @Test func repeatedShapesAreMerged() {
        // "t" and "n" are both consonants.
        #expect(Viseme.sequence(for: "tn") == [.consonant])
    }
}

struct MouthShapeTests {
    @Test func interpolationEndpoints() {
        let a = Viseme.rest.shape, b = Viseme.ai.shape
        #expect(a.interpolated(to: b, amount: 0) == a)
        #expect(a.interpolated(to: b, amount: 1) == b)
    }

    @Test func restIsClosedAndVowelsAreOpen() {
        #expect(Viseme.rest.shape.isClosed)
        #expect(Viseme.mbp.shape.isClosed)
        #expect(!Viseme.ai.shape.isClosed)
        #expect(!Viseme.o.shape.opened(by: 0.5).isClosed)
    }
}

struct LaunchOptionsTests {
    @Test func finderLaunchStartsInTheMenuBar() {
        let options = LaunchOptions.parse([], isCLI: false)
        guard case .menuBar = options.mode else { Issue.record("expected .menuBar"); return }
        #expect(options.portrait.voiceName == "Daniel")
        #expect(!options.isCommandLine)
    }

    @Test(arguments: [
        (["-v", "female"], "Samantha"),
        (["--voice", "male"], "Daniel"),
        (["--voice=female"], "Samantha"),
        (["-v", "FEMALE"], "Samantha"),
    ])
    func voiceOption(arguments: [String], voiceName: String) {
        #expect(LaunchOptions.parse(arguments, isCLI: false).portrait.voiceName == voiceName)
    }

    @Test func speaksAPlainTextFile() throws {
        let url = try temporaryFile("Hello from a file.", extension: "txt")
        let options = LaunchOptions.parse(["-v", "female", "--file", url.path], isCLI: true)
        guard case .speak(let text) = options.mode else { Issue.record("expected .speak"); return }
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == "Hello from a file.")
        #expect(options.portrait.voiceName == "Samantha")
    }

    @Test func speaksTheTextOfAnRTFFile() throws {
        let rtf = try NSAttributedString(string: "Rich text works.")
            .data(from: NSRange(location: 0, length: 16), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".rtf")
        try rtf.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        guard case .speak(let text) = LaunchOptions.parse(["-f", url.path], isCLI: true).mode else {
            Issue.record("expected .speak"); return
        }
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == "Rich text works.")
        #expect(!text.contains("rtf1"))
    }

    @Test(arguments: [
        (["Hello", "there"], "Hello there"),
        (["-v", "female", "Good", "morning!"], "Good morning!"),
        (["Build", "finished", "-v", "male"], "Build finished"),
        (["--", "-5", "degrees", "-v"], "-5 degrees -v"),
        (["-"], "-"),
    ])
    func textArguments(arguments: [String], expected: String) {
        guard case .speak(let text) = LaunchOptions.parse(arguments, isCLI: true).mode else {
            Issue.record("expected .speak"); return
        }
        #expect(text == expected)
    }

    @Test func fileEqualsForm() throws {
        let url = try temporaryFile("Equals form.", extension: "txt")
        guard case .speak(let text) = LaunchOptions.parse(["--file=\(url.path)"], isCLI: true).mode else {
            Issue.record("expected .speak"); return
        }
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == "Equals form.")
    }

    private func temporaryFile(_ contents: String, extension ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

struct TextFragmentTests {
    let page = """
        Talking Head reads text aloud.   The quick brown fox
        jumps over the lazy dog. Then the fox, tired, goes home. The fox sleeps.
        """

    @Test func parsesStartEndPrefixAndSuffix() throws {
        let url = try #require(URL(string: "https://example.com/page#:~:text=the-,fox,home,-.%20The"))
        #expect(TextFragment(url: url) == TextFragment(prefix: "the", start: "fox", end: "home", suffix: ". The"))
    }

    @Test func decodesPercentEncodedCommasAndDashes() throws {
        let url = try #require(URL(string: "https://example.com/#:~:text=fox%2C%20tired%2C%20goes"))
        #expect(TextFragment(url: url) == TextFragment(start: "fox, tired, goes"))
    }

    @Test func ignoresURLsWithoutATextDirective() throws {
        #expect(TextFragment(url: try #require(URL(string: "https://example.com/#section"))) == nil)
        #expect(TextFragment(url: try #require(URL(string: "https://example.com/"))) == nil)
    }

    @Test func findsStartOnlyIgnoringCaseAndWhitespace() throws {
        // The match keeps the page's own text, including its line break.
        let passage = try #require(TextFragment(start: "QUICK brown   fox jumps").passage(in: page))
        #expect(passage.hasPrefix("quick brown fox"))
        #expect(passage.hasSuffix("jumps"))
    }

    @Test func findsStartThroughEnd() {
        #expect(TextFragment(start: "Then the fox", end: "goes home").passage(in: page) == "Then the fox, tired, goes home")
    }

    @Test func prefixAndSuffixPickTheRightOccurrence() {
        // "fox" appears three times; the prefix and suffix select the one before "sleeps".
        #expect(TextFragment(prefix: "The", start: "fox", suffix: "sleeps").passage(in: page) == "fox")
        #expect(TextFragment(prefix: "the", start: "fox", end: "home").passage(in: page) == "fox, tired, goes home")
    }

    @Test func returnsNilWhenNotFound() {
        #expect(TextFragment(start: "purple elephant").passage(in: page) == nil)
    }
}

struct ExternalRequestTests {
    @Test func textRequestWithVoice() throws {
        let url = try #require(URL(string: "talkinghead://speak?text=Hello%20there&voice=female"))
        let request = try #require(ExternalRequests.Request(url: url))
        #expect(request.source == .text("Hello there"))
        #expect(request.portrait == "Samantha")
    }

    @Test func urlRequest() throws {
        let target = "https://example.com/#:~:text=Example"
        let encoded = try #require(target.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let url = try #require(URL(string: "talkinghead://speak?url=\(encoded)"))
        #expect(ExternalRequests.Request(url: url)?.source == .url(try #require(URL(string: target))))
    }

    @Test func rejectsOtherSchemesAndEmptyRequests() throws {
        #expect(ExternalRequests.Request(url: try #require(URL(string: "https://example.com/?text=hi"))) == nil)
        #expect(ExternalRequests.Request(url: try #require(URL(string: "talkinghead://speak"))) == nil)
        #expect(ExternalRequests.Request(url: try #require(URL(string: "talkinghead://speak?url=ftp://x"))) == nil)
    }

    @Test func webURLAcceptsOnlySingleHTTPLinks() {
        #expect(ExternalRequests.webURL("https://apple.com/mac") != nil)
        #expect(ExternalRequests.webURL("see https://apple.com") == nil)
        #expect(ExternalRequests.webURL("mailto:someone@example.com") == nil)
        #expect(ExternalRequests.webURL("hello") == nil)
    }
}

struct AlwaysOnTopOptionTests {
    @Test func flagIsOffByDefaultAndOnWhenGiven() {
        #expect(!LaunchOptions.parse(["Hello"], isCLI: true).alwaysOnTop)
        let options = LaunchOptions.parse(["--always-on-top", "Hello", "there"], isCLI: true)
        #expect(options.alwaysOnTop)
        guard case .speak(let text) = options.mode else { Issue.record("expected .speak"); return }
        #expect(text == "Hello there")
    }
}

struct URLOptionTests {
    @Test func urlOption() throws {
        guard case .speakURL(let url) = LaunchOptions.parse(["-u", "https://example.com/#:~:text=Example"], isCLI: true).mode else {
            Issue.record("expected .speakURL"); return
        }
        #expect(url.host == "example.com")
        #expect(LaunchOptions.parse(["--url=https://example.com"], isCLI: true).speaksAndQuits)
    }
}
