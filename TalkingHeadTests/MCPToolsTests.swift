import Foundation
import MCP
import Testing
@testable import TalkingHead

/// The text of a tool result.
private func text(of result: CallTool.Result) -> String {
    guard case .text(let text, _, _)? = result.content.first else { return "" }
    return text
}

struct MCPArgumentTests {
    @Test func speakDefaults() throws {
        let (request, wait) = try TalkingHeadTools.request(forTool: "speak", arguments: ["text": "Hello"])
        #expect(request == SpeechRequest(source: .text("Hello"), voice: nil, mood: nil))
        #expect(wait)
    }

    @Test func speakWithEverything() throws {
        let (request, wait) = try TalkingHeadTools.request(
            forTool: "speak",
            arguments: ["text": "[happy] Done.", "voice": "Female", "mood": "CONCERNED", "wait": false])
        #expect(request == SpeechRequest(source: .text("[happy] Done."), voice: "female", mood: "concerned"))
        #expect(!wait)
    }

    @Test func speakURL() throws {
        let page = "https://example.com/#:~:text=Example%20Domain"
        let (request, _) = try TalkingHeadTools.request(forTool: "speak_url", arguments: ["url": .string(page)])
        #expect(request.source == .url(URL(string: page)!))
    }

    @Test(arguments: [
        ("speak", [:], "Nothing to speak: give the words in `text`."),
        ("speak", ["text": "   "], "Nothing to speak: the text is empty."),
        ("speak", ["text": 3], "`text` must be a string."),
        ("speak", ["text": "Hi", "mood": "sleepy"],
         "Unknown mood \"sleepy\". Use one of: neutral, happy, sad, surprised, concerned, angry."),
        ("speak", ["text": "Hi", "voice": "robot"], "Unknown voice \"robot\". Use one of: male, female."),
        ("speak", ["text": "Hi", "wait": "yes"], "`wait` must be true or false."),
        ("speak_url", ["url": "ftp://example.com"],
         "ftp://example.com isn't a web address Talking Head can read. Use an http or https URL."),
        ("speak_url", [:], "Give the address of the page to read in `url`."),
        ("sing", ["text": "Hi"], "Talking Head has no tool called sing."),
    ] as [(String, [String: Value], String)])
    func invalidArguments(tool: String, arguments: [String: Value], message: String) {
        #expect(throws: SpeechFailure(message)) {
            _ = try TalkingHeadTools.request(forTool: tool, arguments: arguments)
        }
    }

    @Test func moodsMatchTheApp() {
        #expect(SpeechRequest.moods == Mood.allCases.map(\.rawValue))
    }

    @Test func toolDefinitions() {
        #expect(TalkingHeadTools.tools.map(\.name) == ["speak", "speak_url", "stop"])
        for tool in TalkingHeadTools.tools {
            #expect(tool.annotations.readOnlyHint == false)
            #expect(tool.annotations.destructiveHint == false)
            #expect(tool.annotations.idempotentHint == false)
        }
    }
}

struct THArgumentsTests {
    @Test func textGoesOnStandardInput() {
        let request = SpeechRequest(source: .text("-5 degrees [sad] brr"), voice: "female", mood: "sad")
        #expect(THArguments.arguments(for: request) == ["--always-on-top", "--report-start", "-v", "female", "-m", "sad"])
        #expect(THArguments.standardInput(for: request) == "-5 degrees [sad] brr")
    }

    @Test func pageGoesInURLOption() {
        let url = URL(string: "https://example.com/#:~:text=Example")!
        let request = SpeechRequest(source: .url(url))
        #expect(THArguments.arguments(for: request) == ["--always-on-top", "--report-start", "-u", url.absoluteString])
        #expect(THArguments.standardInput(for: request) == nil)
    }

    @Test func failureMessageFromStandardError() {
        let errors = """
            2026-09-26 [Connection] some AppKit noise
            th: can't read https://example.com/x: The page returned HTTP status 404

            usage: th …
            """
        #expect(THArguments.failureMessage(fromStandardError: errors, status: 2)
                == "Can't read https://example.com/x: The page returned HTTP status 404.")
        #expect(THArguments.failureMessage(fromStandardError: "", status: 9)
                == "Talking Head couldn't speak (th exited with status 9).")
    }
}

/// A speaker that takes `duration` to speak, recording when each request starts and ends.
private actor FakeSpeaker: Speaker {
    private(set) var log: [String] = []
    private var stopped = false
    let duration: Duration
    let failure: SpeechFailure?

    init(duration: Duration = .milliseconds(200), failure: SpeechFailure? = nil) {
        self.duration = duration
        self.failure = failure
    }

    func start(_ request: SpeechRequest) async throws -> SpeechHandle {
        if let failure { throw failure }
        guard case .text(let text) = request.source else { return SpeechHandle { .finished } }
        stopped = false
        log.append("start \(text)")
        return SpeechHandle { [self] in
            let clock = ContinuousClock()
            let end = clock.now + duration
            while clock.now < end {
                if await isStopped { return .stopped }
                try? await Task.sleep(for: .milliseconds(10))
            }
            await record("end \(text)")
            return .finished
        }
    }

    func stop() async {
        stopped = true
        log.append("stop")
    }

    private var isStopped: Bool { stopped }
    private func record(_ entry: String) { log.append(entry) }
}

struct SpeechQueueTests {
    @Test func aSecondCallWaitsForTheFirstToFinish() async throws {
        let speaker = FakeSpeaker()
        let queue = SpeechQueue(speaker: speaker)
        // The first returns as soon as it starts; the second still waits for it to finish.
        #expect(try await queue.speak(SpeechRequest(source: .text("one")), wait: false) == .started)
        #expect(try await queue.speak(SpeechRequest(source: .text("two")), wait: true) == .finished)
        #expect(await speaker.log == ["start one", "end one", "start two", "end two"])
    }

    @Test func concurrentCallsKeepTheirOrder() async throws {
        let speaker = FakeSpeaker(duration: .milliseconds(50))
        let queue = SpeechQueue(speaker: speaker)
        async let first = queue.speak(SpeechRequest(source: .text("a")), wait: true)
        try await Task.sleep(for: .milliseconds(5))
        async let second = queue.speak(SpeechRequest(source: .text("b")), wait: true)
        _ = try await (first, second)
        #expect(await speaker.log == ["start a", "end a", "start b", "end b"])
    }

    @Test func stopEndsTheCurrentSpeechAndDropsTheQueue() async throws {
        let speaker = FakeSpeaker(duration: .seconds(5))
        let queue = SpeechQueue(speaker: speaker)
        async let first = queue.speak(SpeechRequest(source: .text("long")), wait: true)
        async let second = queue.speak(SpeechRequest(source: .text("next")), wait: true)
        try await Task.sleep(for: .milliseconds(100))
        await queue.stop()
        #expect(try await first == .stopped)
        #expect(try await second == .dropped)
        #expect(await speaker.log == ["start long", "stop"])
    }

    @Test func failuresBecomeErrorResults() async {
        let queue = SpeechQueue(speaker: FakeSpeaker(failure: SpeechFailure("Can't read https://example.com: It's gone.")))
        let result = await TalkingHeadTools.call("speak_url", arguments: ["url": "https://example.com"], queue: queue)
        #expect(result.isError == true)
        #expect(text(of: result) == "Can't read https://example.com: It's gone.")
    }

    @Test func invalidArgumentsBecomeErrorResults() async {
        let queue = SpeechQueue(speaker: FakeSpeaker())
        let result = await TalkingHeadTools.call("speak", arguments: ["text": "Hi", "mood": "sleepy"], queue: queue)
        #expect(result.isError == true)
        #expect(text(of: result).hasPrefix("Unknown mood \"sleepy\"."))
    }

    @Test func successAndStopResults() async {
        let queue = SpeechQueue(speaker: FakeSpeaker(duration: .milliseconds(20)))
        let spoken = await TalkingHeadTools.call("speak", arguments: ["text": "Hi"], queue: queue)
        #expect(spoken.isError == false)
        #expect(text(of: spoken) == "Finished speaking.")
        let stopped = await TalkingHeadTools.call("stop", arguments: nil, queue: queue)
        #expect(stopped.isError == false)
    }
}

/// `THProcessSpeaker` against stand-in `th` scripts.
struct THProcessSpeakerTests {
    /// Writes an executable shell script and returns its URL.
    private func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("th-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func finishesWhenThExits() async throws {
        // Echoes its standard input and arguments to a file, reports the start, then "speaks".
        let record = FileManager.default.temporaryDirectory.appendingPathComponent("th-record-\(UUID().uuidString)")
        let th = try script("cat > \(record.path); echo \"$@\" >> \(record.path); echo started; sleep 1")
        let speaker = THProcessSpeaker(executable: th)
        let clock = ContinuousClock()
        let handle = try await speaker.start(SpeechRequest(source: .text("Hello there"), mood: "happy"))
        // `start` returned when the voice started; the end is still most of a second away.
        let started = clock.now
        #expect(try await handle.finished() == .finished)
        #expect(clock.now - started > .milliseconds(700))
        #expect(try String(contentsOf: record, encoding: .utf8)
                == "Hello there--always-on-top --report-start -m happy\n")
    }

    @Test func exitStatus2IsAFailureWithThMessage() async throws {
        let th = try script("echo 'th: couldn'\\''t find the highlighted text on the page' >&2; exit 2")
        let speaker = THProcessSpeaker(executable: th)
        await #expect(throws: SpeechFailure("Couldn't find the highlighted text on the page.")) {
            _ = try await speaker.start(SpeechRequest(source: .url(URL(string: "https://example.com")!)))
        }
    }

    @Test func stopEndsItMidSpeech() async throws {
        let th = try script("cat > /dev/null; echo started; sleep 10")
        let speaker = THProcessSpeaker(executable: th)
        let handle = try await speaker.start(SpeechRequest(source: .text("A long story")))
        let clock = ContinuousClock()
        let stoppedAt = clock.now
        await speaker.stop()
        #expect(try await handle.finished() == .stopped)
        #expect(clock.now - stoppedAt < .seconds(2))
    }
}
