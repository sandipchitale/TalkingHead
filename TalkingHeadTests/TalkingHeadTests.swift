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
        let options = LaunchOptions.parse(["-v", "female", url.path], isCLI: true)
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

        guard case .speak(let text) = LaunchOptions.parse([url.path], isCLI: true).mode else {
            Issue.record("expected .speak"); return
        }
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == "Rich text works.")
        #expect(!text.contains("rtf1"))
    }

    private func temporaryFile(_ contents: String, extension ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
