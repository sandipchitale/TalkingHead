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
    func idle(closingFace: Bool) { faceLog.append(closingFace ? "close" : "idle") }
    func show(presence: Presence) { faceLog.append("\(presence.state.rawValue) \(presence.voice ?? "-")") }
    func nod() { faceLog.append("nod") }

    /// What the face was told, in order.
    private(set) var faceLog: [String] = []
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

// MARK: - Presence

struct PresenceProtocolTests {
    @Test func presenceRoundTrips() throws {
        let listening = SpoolerRequest.presence(.listening, voice: "female")
        #expect(String(decoding: SpoolerCodec.encode(listening), as: UTF8.self)
                == #"{"state":"listening","type":"presence","voice":"female"}"# + "\n")
        #expect(try SpoolerCodec.decode(SpoolerRequest.self, from: SpoolerCodec.encode(listening).dropLast()) == listening)
        let nod = SpoolerRequest.presence(.listening, nod: true)
        #expect(String(decoding: SpoolerCodec.encode(nod), as: UTF8.self)
                == #"{"pulse":"nod","state":"listening","type":"presence"}"# + "\n")
        #expect(String(decoding: SpoolerCodec.encode(SpoolerRequest.presence(.none)), as: UTF8.self)
                == #"{"state":"none","type":"presence"}"# + "\n")
        #expect(String(decoding: SpoolerCodec.encode(SpoolerEvent.presence), as: UTF8.self) == #"{"type":"presence"}"# + "\n")
        #expect(!SpoolerEvent.presence.isFinal)
    }

    @Test func unknownFieldsAreIgnored() throws {
        let line = Data(#"{"type":"presence","state":"thinking","voice":"male","gesture":"x","future":[1,2]}"#.utf8)
        #expect(try SpoolerCodec.decode(SpoolerRequest.self, from: line) == SpoolerRequest.presence(.thinking, voice: "male"))
        let event = try SpoolerCodec.decode(SpoolerEvent.self, from: Data(#"{"type":"finished","extra":true}"#.utf8))
        #expect(event == .finished)
    }

    @Test func speakAndStopAreUnchanged() {
        let speak = SpoolerRequest.speak(SpeechRequest(source: .text("Hi"), voice: "male"), alwaysOnTop: false)
        #expect(String(decoding: SpoolerCodec.encode(speak), as: UTF8.self)
                == #"{"alwaysOnTop":false,"text":"Hi","type":"speak","voice":"male"}"# + "\n")
        #expect(speak.state == nil && speak.pulse == nil)
    }
}

struct PresenceRuleTests {
    private let listening = Presence(state: .listening, voice: "female")
    private let thinking = Presence(state: .thinking, voice: "male")

    @Test func aConnectionsNewestMessageWins() {
        var board = PresenceBoard()
        board.set(owner: 1, listening)
        board.set(owner: 1, Presence(state: .thinking, voice: "female"))
        #expect(board.current == Presence(state: .thinking, voice: "female"))
        board.set(owner: 1, Presence(state: .none))
        #expect(board.current == nil && board.isEmpty)
    }

    @Test func closingAConnectionDropsItsPresence() {
        var board = PresenceBoard()
        board.set(owner: 1, listening)
        board.set(owner: 2, thinking)
        board.drop(owner: 2)
        #expect(board.current == listening)
        board.drop(owner: 1)
        #expect(board.current == nil)
    }

    @Test func theMostRecentlyUpdatedHolderWins() {
        var board = PresenceBoard()
        board.set(owner: 1, listening)
        board.set(owner: 2, thinking)
        #expect(board.current == thinking)
        board.set(owner: 1, listening)  // re-sent: now the most recent
        #expect(board.current == listening)
        board.set(owner: 1, Presence(state: .none))
        #expect(board.current == thinking)
    }

    @Test func speechOverridesPresence() {
        #expect(FaceMode.resolve(speaking: true, presence: thinking) == .speaking)
        #expect(FaceMode.resolve(speaking: false, presence: thinking) == .thinking(voice: "male"))
        #expect(FaceMode.resolve(speaking: false, presence: listening) == .listening(voice: "female"))
        #expect(FaceMode.resolve(speaking: false, presence: nil) == .hidden)
        #expect(FaceMode.resolve(speaking: true, presence: nil) == .speaking)
    }

    @Test func theFaceClosesOnlyWhenNothingIsQueuedOrHeld() {
        #expect(FaceMode.shouldClose(queueEmpty: true, presence: nil))
        #expect(!FaceMode.shouldClose(queueEmpty: false, presence: nil))
        #expect(!FaceMode.shouldClose(queueEmpty: true, presence: listening))
        #expect(!FaceMode.shouldClose(queueEmpty: false, presence: thinking))
    }
}

@MainActor
struct PresenceSpoolerTests {
    @Test func presenceIsShownAndDropped() {
        let performer = FakePerformer()
        let spooler = SpeechSpooler(performer: performer)
        spooler.setPresence(owner: 1, Presence(state: .listening, voice: "female"))
        spooler.setPresence(owner: 1, Presence(state: .listening, voice: "female"), nod: true)
        spooler.setPresence(owner: 1, Presence(state: .thinking, voice: "female"))
        spooler.dropPresence(owner: 1)
        #expect(performer.faceLog == ["listening female", "listening female", "nod", "thinking female", "idle"])
    }

    @Test func speechOverridesPresenceAndTheFaceReturnsToIt() async {
        let performer = FakePerformer(duration: .milliseconds(150))
        let spooler = SpeechSpooler(performer: performer)
        spooler.setPresence(owner: 1, Presence(state: .thinking))
        spooler.submit(text("reply"), owner: 2)
        // Changed mid-speech: recorded, applied once the speech ends. Nods are for idle faces only.
        spooler.setPresence(owner: 1, Presence(state: .listening), nod: true)
        await eventually { performer.log.count == 2 }
        await eventually { performer.faceLog.count == 2 }
        #expect(performer.faceLog == ["thinking -", "listening -"])
        #expect(spooler.currentPresence == Presence(state: .listening))
    }

    @Test func stopClearsSpeechButNotPresence() async {
        let performer = FakePerformer(duration: .seconds(5))
        let spooler = SpeechSpooler(performer: performer)
        spooler.setPresence(owner: 1, Presence(state: .listening))
        spooler.submit(text("a"), owner: 2)
        spooler.submit(text("b"), owner: 3)
        await eventually { performer.log == ["start a"] }
        spooler.stopAll(closingFace: true)
        await eventually { spooler.current == nil }
        await eventually { performer.faceLog.count == 2 }
        #expect(spooler.waiting.isEmpty)
        #expect(spooler.currentPresence == Presence(state: .listening))
        #expect(performer.faceLog == ["listening -", "listening -"])  // never closed
    }

    @Test func stopWithoutPresenceStillClosesTheFace() {
        let performer = FakePerformer()
        let spooler = SpeechSpooler(performer: performer)
        spooler.stopAll(closingFace: true)
        #expect(performer.faceLog == ["close"])
    }
}

/// Presence over the socket, as VoiceChat uses it.
@MainActor
struct PresenceServerTests {
    /// Opens a connection and sends `requests`, returning the events received for them.
    private func send(_ connection: SpoolerConnection, _ requests: SpoolerRequest...) async -> [SpoolerEvent] {
        for request in requests { connection.send(request) }
        let count = requests.count
        return await Task.detached {
            var events: [SpoolerEvent] = []
            while events.count < count, let event = connection.nextEvent() { events.append(event) }
            return events
        }.value
    }

    private func serve(_ performer: FakePerformer) throws -> (String, SpeechSpooler, SpoolerServer) {
        let path = socketPath()
        let spooler = SpeechSpooler(performer: performer)
        let server = SpoolerServer(path: path, spooler: spooler)
        try server.start()
        return (path, spooler, server)
    }

    @Test func presenceIsAcknowledgedAndDroppedOnClose() async throws {
        let performer = FakePerformer()
        let (path, spooler, server) = try serve(performer)
        defer { server.stop() }

        let connection = try #require(SpoolerConnection.open(at: path))
        #expect(await send(connection, .presence(.listening, voice: "female"), .presence(.listening, voice: "female", nod: true))
                == [.presence, .presence])
        #expect(spooler.currentPresence == Presence(state: .listening, voice: "female"))
        #expect(performer.faceLog == ["listening female", "listening female", "nod"])

        connection.close()
        await eventually { spooler.currentPresence == nil }
        await eventually { performer.faceLog.last == "idle" }
        #expect(performer.faceLog.last == "idle")
    }

    @Test func badPresenceIsRefusedAndOddVoicesIgnored() async throws {
        let (path, spooler, server) = try serve(FakePerformer())
        defer { server.stop() }
        let connection = try #require(SpoolerConnection.open(at: path))
        defer { connection.close() }
        let refused = await send(connection, SpoolerRequest(type: .presence, state: "dozing"))
        #expect(refused.first?.type == .error)
        #expect(spooler.currentPresence == nil)
        #expect(await send(connection, SpoolerRequest(type: .presence, voice: "robot", state: "thinking")) == [.presence])
        #expect(spooler.currentPresence == Presence(state: .thinking))
    }

    @Test func aSpeechReturnsToThePresenceHeld() async throws {
        let performer = FakePerformer()
        let (path, spooler, server) = try serve(performer)
        defer { server.stop() }

        let presence = try #require(SpoolerConnection.open(at: path))
        defer { presence.close() }
        #expect(await send(presence, .presence(.thinking, voice: "male")) == [.presence])

        let speech = try #require(SpoolerConnection.open(at: path))
        speech.send(.speak(text("reply", voice: "male"), alwaysOnTop: true))
        let kinds = await Task.detached {
            var kinds: [SpoolerEvent.Kind] = []
            while let event = speech.nextEvent() {
                kinds.append(event.type)
                if event.isFinal { break }
            }
            return kinds
        }.value
        #expect(kinds == [.queued, .started, .finished])
        await eventually { performer.faceLog.count == 2 }
        #expect(performer.faceLog == ["thinking male", "thinking male"])
        #expect(spooler.currentPresence == Presence(state: .thinking, voice: "male"))
    }

    @Test func stopOverTheSocketKeepsPresence() async throws {
        let performer = FakePerformer(duration: .seconds(5))
        let (path, spooler, server) = try serve(performer)
        defer { server.stop() }

        let presence = try #require(SpoolerConnection.open(at: path))
        defer { presence.close() }
        #expect(await send(presence, .presence(.listening)) == [.presence])
        let speech = try #require(SpoolerConnection.open(at: path))
        defer { speech.close() }
        speech.send(.speak(text("long"), alwaysOnTop: false))
        await eventually { performer.log == ["start long"] }

        let stop = try #require(SpoolerConnection.open(at: path))
        defer { stop.close() }
        #expect(await send(stop, .stop) == [.stopped])
        await eventually { spooler.current == nil }
        await eventually { performer.faceLog.count == 2 }
        #expect(performer.faceLog == ["listening -", "listening -"])
        #expect(spooler.currentPresence == Presence(state: .listening))
    }
}
