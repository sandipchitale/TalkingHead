import Foundation
import MCP
import Testing
@testable import TalkingHead

/// Speaks nothing: each job "speaks" for `duration` (a page fails), recording what happened.
@MainActor
private final class FakePerformer: SpoolPerformer {
    private(set) var log: [String] = []
    private(set) var voices: [String?] = []
    private var stopped = false
    let duration: Duration

    init(duration: Duration = .milliseconds(80)) {
        self.duration = duration
    }

    func perform(_ job: SpoolJob, started: @escaping () -> Void) async throws -> SpeechEnd {
        guard case .text(let text) = job.request.source else { throw SpeechFailure("Can't read that page.") }
        stopped = false
        voices.append(job.request.voice)
        log.append("start \(text)")
        started()
        let end = ContinuousClock.now + duration
        while ContinuousClock.now < end {
            if stopped {
                log.append("stopped \(text)")
                return .stopped
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        log.append("end \(text)")
        return .finished
    }

    func stopCurrent() { stopped = true }
    func idle(closingFace: Bool) {}
}

private func text(_ words: String, voice: String? = nil) -> SpeechRequest {
    SpeechRequest(source: .text(words), voice: voice)
}

/// Waits (briefly) until `condition` holds.
@MainActor
private func eventually(_ condition: () -> Bool) async {
    for _ in 0..<400 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// A short socket path in the temporary folder (Unix socket paths are limited to 104 bytes).
private func socketPath() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("th-\(UUID().uuidString.prefix(8)).sock").path
}

struct SpoolerProtocolTests {
    @Test func speakRoundTrips() throws {
        let request = SpeechRequest(source: .text("Hello [happy] there"), voice: "female", mood: "sad")
        let message = SpoolerRequest.speak(request, alwaysOnTop: true)
        let line = SpoolerCodec.encode(message)
        #expect(String(decoding: line, as: UTF8.self)
                == #"{"alwaysOnTop":true,"mood":"sad","text":"Hello [happy] there","type":"speak","voice":"female"}"# + "\n")
        let decoded = try SpoolerCodec.decode(SpoolerRequest.self, from: line.dropLast())
        #expect(try decoded.speechRequest() == request)
    }

    @Test func urlAndStop() throws {
        let url = URL(string: "https://example.com/#:~:text=Example")!
        let message = SpoolerRequest.speak(SpeechRequest(source: .url(url)), alwaysOnTop: false)
        #expect(try message.speechRequest().source == .url(url))
        #expect(String(decoding: SpoolerCodec.encode(SpoolerRequest.stop), as: UTF8.self) == #"{"type":"stop"}"# + "\n")
    }

    @Test func events() throws {
        let error = try SpoolerCodec.decode(SpoolerEvent.self, from: Data(#"{"type":"error","message":"Nope."}"#.utf8))
        #expect(error == .error("Nope."))
        #expect(error.isFinal)
        #expect(!SpoolerEvent.queued.isFinal && !SpoolerEvent.started.isFinal)
        #expect(SpoolerEvent.finished.isFinal && SpoolerEvent.stopped.isFinal)
    }

    @Test func badRequestsAreRefused() {
        #expect(throws: SpeechFailure.self) { try SpoolerRequest(type: .speak, text: "  ").speechRequest() }
        #expect(throws: SpeechFailure.self) { try SpoolerRequest(type: .speak, text: "Hi", mood: "sleepy").speechRequest() }
        #expect(throws: SpeechFailure.self) { try SpoolerRequest(type: .speak, url: "ftp://x").speechRequest() }
    }

    @Test func linesAreSplit() {
        var buffer = LineBuffer()
        #expect(buffer.append(Data("{\"a\":1}\n{\"b\"".utf8)).map { String(decoding: $0, as: UTF8.self) } == [#"{"a":1}"#])
        #expect(buffer.append(Data(":2}\n".utf8)).map { String(decoding: $0, as: UTF8.self) } == [#"{"b":2}"#])
    }
}

@MainActor
struct SpeechSpoolerTests {
    @Test func speaksEveryonesSpeechInArrivalOrder() async {
        let performer = FakePerformer()
        let spooler = SpeechSpooler(performer: performer)
        var events: [String] = []
        for (owner, words) in [(1, "one"), (2, "two"), (3, "three")] {
            spooler.submit(text(words), owner: owner) { events.append("\(words) \($0.type)") }
        }
        await eventually { performer.log.count == 6 }
        #expect(performer.log == ["start one", "end one", "start two", "end two", "start three", "end three"])
        #expect(events.filter { $0.hasPrefix("two") } == ["two queued", "two started", "two finished"])
    }

    @Test func aDisconnectedCallerTakesOnlyItsOwnSpeech() async {
        let performer = FakePerformer(duration: .milliseconds(300))
        let spooler = SpeechSpooler(performer: performer)
        var ended: [String: SpoolerEvent.Kind] = [:]
        for (owner, words) in [(1, "a"), (2, "b"), (1, "c"), (3, "d")] {
            spooler.submit(text(words), owner: owner) { if $0.isFinal { ended[words] = $0.type } }
        }
        await eventually { performer.log == ["start a"] }
        spooler.cancelAll(owner: 1)  // stops "a" (speaking) and drops "c" (waiting)
        await eventually { ended.count == 4 }
        #expect(ended == ["a": .stopped, "b": .finished, "c": .stopped, "d": .finished])
        #expect(!performer.log.contains("start c"))
    }

    @Test func stopClearsEverything() async {
        let performer = FakePerformer(duration: .seconds(5))
        let spooler = SpeechSpooler(performer: performer)
        var ended: [String: SpoolerEvent.Kind] = [:]
        for (owner, words) in [(1, "a"), (2, "b"), (3, "c")] {
            spooler.submit(text(words), owner: owner) { if $0.isFinal { ended[words] = $0.type } }
        }
        await eventually { performer.log == ["start a"] }
        spooler.stopAll()
        await eventually { ended.count == 3 }
        #expect(ended == ["a": .stopped, "b": .stopped, "c": .stopped])
        #expect(spooler.waiting.isEmpty)
        await eventually { spooler.current == nil }
        #expect(spooler.current == nil)
    }

    @Test func aPageThatCantBeReadIsAnError() async {
        let spooler = SpeechSpooler(performer: FakePerformer())
        var last: SpoolerEvent?
        spooler.submit(SpeechRequest(source: .url(URL(string: "https://example.com")!))) { last = $0 }
        await eventually { last?.isFinal == true }
        #expect(last == .error("Can't read that page."))
    }
}

/// The spooler over its socket, as `th` and `th-mcp` use it.
@MainActor
struct SpoolerServerTests {
    /// Sends `request` on a new connection and collects its events on a background thread.
    private func client(_ path: String, _ request: SpoolerRequest) -> (SpoolerConnection, Task<[SpoolerEvent.Kind], Never>) {
        let connection = SpoolerConnection.open(at: path)!
        connection.send(request)
        let events = Task.detached {
            var kinds: [SpoolerEvent.Kind] = []
            while let event = connection.nextEvent() {
                kinds.append(event.type)
                if event.isFinal { break }
            }
            return kinds
        }
        return (connection, events)
    }

    @Test func closingAConnectionDropsOnlyItsRequest() async throws {
        let path = socketPath()
        let performer = FakePerformer(duration: .milliseconds(300))
        let spooler = SpeechSpooler(performer: performer)
        let server = SpoolerServer(path: path, spooler: spooler)
        try server.start()
        defer { server.stop() }

        let (_, first) = client(path, .speak(text("first"), alwaysOnTop: false))
        await eventually { performer.log == ["start first"] }
        let (killed, second) = client(path, .speak(text("second"), alwaysOnTop: false))
        let (_, third) = client(path, .speak(text("third"), alwaysOnTop: false))
        await eventually { spooler.waiting.count == 2 }
        killed.close()  // as when `th` is sent SIGTERM while waiting its turn

        #expect(await first.value == [.queued, .started, .finished])
        #expect(await third.value == [.queued, .started, .finished])
        _ = await second.value
        #expect(performer.log == ["start first", "end first", "start third", "end third"])
    }

    @Test func stopOverTheSocketSilencesEveryone() async throws {
        let path = socketPath()
        let performer = FakePerformer(duration: .seconds(5))
        let spooler = SpeechSpooler(performer: performer)
        let server = SpoolerServer(path: path, spooler: spooler)
        try server.start()
        defer { server.stop() }

        let (_, first) = client(path, .speak(text("first"), alwaysOnTop: false))
        let (_, second) = client(path, .speak(text("second"), alwaysOnTop: false))
        await eventually { performer.log == ["start first"] && spooler.waiting.count == 1 }
        let (_, stop) = client(path, .stop)
        #expect(await stop.value == [.stopped])
        #expect(await first.value.last == .stopped)
        #expect(await second.value == [.queued, .stopped])
    }

    @Test func socketAndFolderArePrivate() throws {
        let path = socketPath()
        let server = SpoolerServer(path: path, spooler: SpeechSpooler(performer: FakePerformer()))
        try server.start()
        defer { server.stop() }
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // A second server can't take over a socket that is being served.
        #expect(throws: UnixSocket.Failure.self) {
            try SpoolerServer(path: path, spooler: SpeechSpooler(performer: FakePerformer())).start()
        }
    }

    @Test func thForwardsAndKeepsItsContract() async throws {
        let path = socketPath()
        let performer = FakePerformer()
        let server = SpoolerServer(path: path, spooler: SpeechSpooler(performer: performer))
        try server.start()
        defer { server.stop() }

        let female = LaunchOptions(mode: .speak("Hello"), portrait: .woman, mood: .happy, alwaysOnTop: true)
        #expect(Forwarding.request(for: female)
                == SpoolerRequest(type: .speak, text: "Hello", voice: "female", mood: "happy", alwaysOnTop: true))
        // th names its voice even when -v wasn't given: male, as always.
        #expect(Forwarding.request(for: LaunchOptions(mode: .speak("Hi"), portrait: .man))?.voice == "male")
        #expect(Forwarding.request(for: LaunchOptions(mode: .face, portrait: .man)) == nil)

        let hello = Forwarding.request(for: female)!
        let status = await Task.detached { Forwarding.forward(hello, reportsStart: false, socketPath: path) }.value
        #expect(status == 0)
        #expect(performer.log == ["start Hello", "end Hello"])

        let page = Forwarding.request(for: LaunchOptions(mode: .speakURL(URL(string: "https://example.com")!), portrait: .man))!
        #expect(await Task.detached { Forwarding.forward(page, reportsStart: false, socketPath: path) }.value == 2)

        // No app listening: th shows its own face instead.
        #expect(Forwarding.forward(female, socketPath: socketPath()) == nil)
    }
}

struct MCPWaitTests {
    /// Speaks for `duration`.
    private actor SlowSpeaker: Speaker {
        let duration: Duration
        init(_ duration: Duration) { self.duration = duration }
        func start(_ request: SpeechRequest) async throws -> SpeechHandle {
            let duration = duration
            return SpeechHandle {
                try? await Task.sleep(for: duration)
                return .finished
            }
        }
        func stop() async {}
    }

    private actor Messages {
        var all: [String] = []
        func add(_ message: String) { all.append(message) }
    }

    @Test func aLongCallReturnsWhileTheSpeechCarriesOn() async {
        let queue = SpeechQueue(speaker: SlowSpeaker(.seconds(2)))
        let messages = Messages()
        let clock = ContinuousClock()
        let began = clock.now
        let result = await TalkingHeadTools.call("speak", arguments: ["text": "A long reading"], queue: queue,
                                                 waitLimit: .milliseconds(500), interval: .milliseconds(150)) {
            await messages.add($0)
        }
        #expect(clock.now - began < .seconds(1))
        #expect(result.isError == false)
        guard case .text(let text, _, _)? = result.content.first else { return }
        #expect(text == "Still speaking. It will finish on its own; don't call again to repeat it.")
        #expect(await messages.all.first == "Speaking…")
    }

    @Test func waitingForATurnSaysSo() async {
        let queue = SpeechQueue(speaker: SlowSpeaker(.seconds(2)))
        _ = try? await queue.speak(SpeechRequest(source: .text("First")), wait: false)
        let messages = Messages()
        let result = await TalkingHeadTools.call("speak", arguments: ["text": "Second", "wait": false], queue: queue,
                                                 waitLimit: .milliseconds(400), interval: .milliseconds(100)) {
            await messages.add($0)
        }
        guard case .text(let text, _, _)? = result.content.first else { return }
        #expect(text.hasPrefix("Waiting for earlier speech to finish"))
        #expect(await messages.all.first == "Waiting for earlier speech…")
    }

    @Test func aQuickCallJustFinishes() async {
        let queue = SpeechQueue(speaker: SlowSpeaker(.milliseconds(50)))
        let result = await TalkingHeadTools.call("speak", arguments: ["text": "Hi"], queue: queue,
                                                 waitLimit: .seconds(5), interval: .seconds(1))
        guard case .text(let text, _, _)? = result.content.first else { return }
        #expect(text == "Finished speaking.")
    }
}

struct OmittedVoiceTests {
    @Test func theAppsChoiceFillsIn() {
        #expect(SavedVoice.resolve(nil, saved: "female") == "female")
        #expect(SavedVoice.resolve("male", saved: "female") == "male")
        #expect(SavedVoice.resolve(nil, saved: nil) == "male")
    }

    /// With no app running, th-mcp runs `th`, naming the app's saved voice.
    @Test func thMCPFallbackUsesTheSavedVoice() async throws {
        let record = FileManager.default.temporaryDirectory.appendingPathComponent("th-args-\(UUID().uuidString)")
        let th = FileManager.default.temporaryDirectory.appendingPathComponent("th-\(UUID().uuidString)")
        try "#!/bin/sh\ncat > /dev/null; echo \"$@\" > \(record.path); echo started\n"
            .write(to: th, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: th.path)

        let speaker = RoutingSpeaker(th: th, socketPath: socketPath(), savedVoice: { "female" })
        let handle = try await speaker.start(SpeechRequest(source: .text("Hi")))
        _ = try await handle.finished()
        #expect(try String(contentsOf: record, encoding: .utf8) == "--always-on-top --report-start -v female\n")
    }

    /// Through the spooler, an omitted voice reaches the app as omitted, so it uses its own.
    @MainActor
    @Test func theSpoolerLeavesItToTheApp() async throws {
        let path = socketPath()
        let performer = FakePerformer()
        let server = SpoolerServer(path: path, spooler: SpeechSpooler(performer: performer))
        try server.start()
        defer { server.stop() }

        let speaker = RoutingSpeaker(th: URL(fileURLWithPath: "/nonexistent"), socketPath: path, savedVoice: { "female" })
        let handle = try await speaker.start(SpeechRequest(source: .text("Hi")))
        #expect(try await handle.finished() == .finished)
        #expect(performer.voices == [nil])
    }
}
