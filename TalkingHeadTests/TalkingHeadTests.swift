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

struct EmphasisTests {
    private func raises(_ word: String, in text: String) -> Bool {
        Emphasis.raisesBrows((text as NSString).range(of: word, options: .backwards), in: text)
    }

    @Test func firstWordIsStressed() {
        #expect(raises("Hello", in: "Hello there, friend."))
        #expect(raises("Hello", in: "\"Hello there.\""))
    }

    @Test func ordinaryWordsAreNot() {
        #expect(!raises("there", in: "Hello there, friend."))
        #expect(!raises("left", in: "Then I left."))
    }

    @Test func sentencesAndClausesStartStressed() {
        #expect(raises("friend", in: "Hello there, friend."))
        #expect(raises("Then", in: "It rained. Then I left."))
        #expect(raises("Then", in: "It rained. \"Then I left.\""))
    }

    @Test func questionsExclamationsCapitalsAndLongWords() {
        #expect(raises("ready", in: "Are you ready?"))
        #expect(raises("wow", in: "That was, wow!"))
        #expect(raises("NOW", in: "Do it NOW."))
        #expect(raises("amazing", in: "It is amazing here."))
    }

    @Test func singleCapitalLetterIsNotShouting() {
        #expect(!raises("I", in: "Then I left."))
    }

    private func brows(_ word: String, in text: String) -> Double? {
        Emphasis.brows(for: (text as NSString).range(of: word, options: .backwards), in: text)
    }

    @Test func negativeWordsLowerTheBrows() {
        #expect(brows("not", in: "That is not right.")! < 0)
        #expect(brows("don't", in: "I don't know.")! < 0)
        #expect(brows("can’t", in: "We can’t.")! < 0)
        // Lowering wins over the raise a sentence start or capitals would give.
        #expect(brows("But", in: "It works. But slowly.")! < 0)
        #expect(brows("NOT", in: "Do NOT touch.")! < 0)
    }

    @Test func questionsAndExclamationsRaiseHigher() {
        #expect(brows("ready", in: "Are you ready?") == Emphasis.exclaimedLift)
        #expect(brows("wow", in: "That was, wow!") == Emphasis.exclaimedLift)
        #expect(brows("not", in: "Why not?") == Emphasis.exclaimedLift)
        #expect(brows("Hello", in: "Hello there.") == 1)
    }

    @Test func browsRiseOrStayPut() {
        #expect(brows("Hello", in: "Hello there.") == 1)
        #expect(brows("there", in: "Hello there.") == nil)
    }
}

struct BrowRegionTests {
    @Test func browWeightFadesAtTheEnds() {
        let brow = BrowRegion(minX: 100, maxX: 200, top: 0, line: 10, bottom: 20)
        #expect(brow.weight(atX: 100) == 0)
        #expect(brow.weight(atX: 200) == 0)
        #expect(brow.weight(atX: 150) == 1)
        #expect(brow.weight(atX: 110) > 0 && brow.weight(atX: 110) < 1)
    }
}

struct ScriptTests {
    private func moodOf(_ word: String, in script: Script) -> Mood {
        script.mood(at: (script.text as NSString).range(of: word).location)
    }

    @Test func cuesAreRemovedAndApplyUntilTheNext() {
        let script = Script.parse("[happy] Hello there. [sad] I have to go. [neutral] Bye.")
        #expect(script.text == "Hello there. I have to go. Bye.")
        #expect(moodOf("Hello", in: script) == .happy)
        #expect(moodOf("go", in: script) == .sad)
        #expect(moodOf("Bye", in: script) == .neutral)
    }

    @Test func unknownBracketsAreLeftAlone() {
        #expect(Script.parse("See note [1] and [HAPPY] too").text == "See note [1] and too")
    }

    @Test func emojiSetTheirSentencesMood() {
        let script = Script.parse("Well done! 😊 The build broke 😟 again.")
        #expect(script.text == "Well done! The build broke again.")
        #expect(moodOf("done", in: script) == .happy)
        #expect(moodOf("broke", in: script) == .concerned)
    }

    @Test func emoticonsCountButNotInsideWords() {
        let script = Script.parse("That is sad :( really.")
        #expect(script.text == "That is sad really.")
        #expect(moodOf("sad", in: script) == .sad)
        #expect(Script.parse("See https://example.com today").text == "See https://example.com today")
    }

    @Test func feelingWordsSuggestAMood() {
        let script = Script.parse("Congratulations on the release. The tests ran. Unfortunately, the deploy failed.")
        #expect(moodOf("release", in: script) == .happy)
        #expect(moodOf("ran", in: script) == .neutral)
        // "unfortunately" (sad) and "failed" (concerned) tie; the first wins.
        #expect(moodOf("deploy", in: script) == .sad)
    }

    @Test func aGivenMoodOverridesGuessesButNotCues() {
        let script = Script.parse("Great news. [surprised] Really?", mood: .concerned)
        #expect(moodOf("Great", in: script) == .concerned)
        #expect(moodOf("Really", in: script) == .surprised)
    }

    @Test func offsetsAreUTF16() {
        // "é" is one UTF-16 unit, "🚀" (not a mood emoji, so kept) is two.
        let script = Script.parse("Café 🚀 [angry] Stop.")
        #expect(moodOf("Stop", in: script) == .angry)
        #expect(moodOf("Café", in: script) == .neutral)
    }
}

struct MoodOptionTests {
    @Test func moodOption() {
        #expect(LaunchOptions.parse(["--mood", "happy", "Hi"], isCLI: true).mood == .happy)
        #expect(LaunchOptions.parse(["-m", "SAD", "Hi"], isCLI: true).mood == .sad)
        #expect(LaunchOptions.parse(["--mood=angry", "Hi"], isCLI: true).mood == .angry)
        #expect(LaunchOptions.parse(["Hi"], isCLI: true).mood == nil)
    }

    @Test func moodInLinks() throws {
        let url = try #require(URL(string: "talkinghead://speak?text=Hi&mood=surprised"))
        #expect(ExternalRequests.Request(url: url)?.mood == .surprised)
        let unknown = try #require(URL(string: "talkinghead://speak?text=Hi&mood=sleepy"))
        #expect(ExternalRequests.Request(url: unknown)?.mood == nil)
    }
}

struct ProsodyTests {
    /// A buzzy (harmonic-rich) tone, like a voice.
    private func tone(_ frequency: Double, sampleRate: Double = 22_050, count: Int = 1024) -> [Float] {
        (0..<count).map { i in
            let t = Double(i) / sampleRate
            return Float(0.3 * sin(2 * .pi * frequency * t) + 0.15 * sin(4 * .pi * frequency * t)
                         + 0.1 * sin(6 * .pi * frequency * t))
        }
    }

    @Test(arguments: [110.0, 175.0, 240.0])
    func findsThePitch(of frequency: Double) {
        let found = Double(PitchTracker.fundamental(of: tone(frequency), sampleRate: 22_050))
        #expect(abs(found - frequency) / frequency < 0.03)
    }

    @Test func silenceIsUnvoiced() {
        #expect(PitchTracker.fundamental(of: [Float](repeating: 0, count: 1024), sampleRate: 22_050) == 0)
    }

    @Test func aWordAboveTheUsualPitchIsAccented() {
        // 200 windows around 120 Hz, then a word at 150 Hz (about 4 semitones up).
        let pitches = (0..<200).map { Float($0 % 2 == 0 ? 115 : 125) } + [Float](repeating: 150, count: 8)
        let high = WordProsody.measure(word: 200..<208, pitches: pitches)
        let usual = WordProsody.measure(word: 0..<8, pitches: pitches)
        #expect(high!.accent > 0.5)
        #expect(usual!.accent == 0)
    }

    @Test func pitchAccentDrivesOrdinaryRaises() {
        let text = "The build finished today."
        let build = (text as NSString).range(of: "build")
        let today = (text as NSString).range(of: "today")
        #expect(Emphasis.brows(for: build, in: text, accent: 0.8)! > 0)
        #expect(Emphasis.brows(for: build, in: text, accent: 0) == nil)
        // A sentence start raises without pitch data, but not when the voice doesn't stress it.
        #expect(Emphasis.brows(for: NSRange(location: 0, length: 3), in: text) == 1)
        #expect(Emphasis.brows(for: NSRange(location: 0, length: 3), in: text, accent: 0) == nil)
        #expect(Emphasis.brows(for: today, in: text, accent: 0.1) == nil)
    }
}
