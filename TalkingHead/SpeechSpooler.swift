import AppKit

/// One queued speech.
final class SpoolJob {
    let id: Int
    let request: SpeechRequest
    /// The spooler connection it came from, if any, so a caller that goes away takes its speech
    /// with it.
    let owner: Int?
    /// Float the face above other windows while this speaks.
    let alwaysOnTop: Bool
    /// Close the face after the queue empties, if speaking this opened it.
    let closesFace: Bool
    /// Told `queued`, then `started`, then one of `finished`, `stopped` or `error`.
    let onEvent: (SpoolerEvent) -> Void

    init(id: Int, request: SpeechRequest, owner: Int?, alwaysOnTop: Bool, closesFace: Bool,
         onEvent: @escaping (SpoolerEvent) -> Void) {
        self.id = id
        self.request = request
        self.owner = owner
        self.alwaysOnTop = alwaysOnTop
        self.closesFace = closesFace
        self.onEvent = onEvent
    }
}

/// Speaks jobs for the spooler (the app's face, or a stand-in in tests).
protocol SpoolPerformer: AnyObject {
    /// Speaks `job`, calling `started` when the voice starts. Returns how it ended; throws
    /// `SpeechFailure` if it can't be spoken.
    func perform(_ job: SpoolJob, started: @escaping () -> Void) async throws -> SpeechEnd
    /// Stops the job being performed.
    func stopCurrent()
    /// The queue has emptied and nobody holds presence (after a stop, with `closingFace` if the
    /// face should close now).
    func idle(closingFace: Bool)
    /// Nothing is speaking and someone holds `presence`: show it, opening the face if need be.
    func show(presence: Presence)
    /// A one-shot nod, while showing presence.
    func nod()
}

/// The one queue for everything the face says: `th` and `th-mcp` (through `SpoolerServer`), the
/// HTTP MCP server, links, the Services menu, and the app's own typing window, file button and
/// Play. Speech is spoken in the order it arrives, one at a time.
///
/// It also keeps the face's presence (listening, thinking) between speeches, as clients on the
/// socket ask for it. Presence is never queued: speech overrides it, and the face returns to it
/// when the queue empties instead of closing.
final class SpeechSpooler {
    static var shared: SpeechSpooler!

    private let performer: SpoolPerformer
    private var queue: [SpoolJob] = []
    private(set) var current: SpoolJob?
    private var running: Task<Void, Never>?
    /// Set when the current job was cancelled, so its end is reported as stopped.
    private var cancelledCurrent = false
    private var nextID = 0
    private var presence = PresenceBoard()

    init(performer: SpoolPerformer) {
        self.performer = performer
    }

    /// Everything waiting, in order (the one speaking isn't included).
    var waiting: [SpoolJob] { queue }

    /// The presence being held, if any (shown whenever nothing is speaking).
    var currentPresence: Presence? { presence.current }

    // MARK: Presence

    /// Connection `owner`'s newest presence (a `none` state drops it), with an optional nod.
    func setPresence(owner: Int, _ state: Presence, nod: Bool = false) {
        presence.set(owner: owner, state)
        settle()
        if nod, current == nil, presence.current != nil { performer.nod() }
    }

    /// Connection `owner` closed: its presence goes with it.
    func dropPresence(owner: Int) {
        presence.drop(owner: owner)
        settle()
    }

    /// With nothing speaking, shows the presence being held, or lets the face go. While speech is
    /// under way nothing changes: the face never switches in the middle of a speech.
    private func settle(closingFace: Bool = false) {
        guard current == nil, queue.isEmpty else { return }
        if let shown = presence.current {
            performer.show(presence: shown)
        } else {
            performer.idle(closingFace: closingFace)
        }
    }

    // MARK: Speech

    @discardableResult
    func submit(_ request: SpeechRequest, owner: Int? = nil, alwaysOnTop: Bool = false, closesFace: Bool = false,
                onEvent: @escaping (SpoolerEvent) -> Void = { _ in }) -> SpoolJob {
        nextID += 1
        let job = SpoolJob(id: nextID, request: request, owner: owner, alwaysOnTop: alwaysOnTop,
                           closesFace: closesFace, onEvent: onEvent)
        queue.append(job)
        job.onEvent(.queued)
        startNext()
        return job
    }

    /// Takes back one job: dropped if waiting, stopped if speaking.
    func cancel(_ job: SpoolJob) {
        if let index = queue.firstIndex(where: { $0 === job }) {
            queue.remove(at: index).onEvent(.stopped)
        } else if current === job {
            stopCurrent()
        }
    }

    /// Takes back everything `owner` asked for (its connection closed).
    func cancelAll(owner: Int) {
        let dropped = queue.filter { $0.owner == owner }
        queue.removeAll { $0.owner == owner }
        for job in dropped { job.onEvent(.stopped) }
        if current?.owner == owner { stopCurrent() }
    }

    /// Silence: stops the current speech and clears the whole queue, whoever queued it. Presence
    /// isn't speech, so it stays, and the face returns to it.
    func stopAll(closingFace: Bool = false) {
        let dropped = queue
        queue.removeAll()
        for job in dropped { job.onEvent(.stopped) }
        if current != nil {
            stopCurrent()
            // The speech's end settles the face; with nobody holding presence, close it now.
            if closingFace, presence.current == nil { performer.idle(closingFace: true) }
        } else {
            settle(closingFace: closingFace)
        }
    }

    private func stopCurrent() {
        cancelledCurrent = true
        running?.cancel()
        performer.stopCurrent()
    }

    private func startNext() {
        guard current == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        current = job
        cancelledCurrent = false
        running = Task { await run(job) }
    }

    private func run(_ job: SpoolJob) async {
        do {
            let end = try await performer.perform(job) { job.onEvent(.started) }
            job.onEvent(end == .finished && !cancelledCurrent ? .finished : .stopped)
        } catch let failure as SpeechFailure {
            job.onEvent(cancelledCurrent ? .stopped : .error(failure.message))
        } catch {
            job.onEvent(cancelledCurrent ? .stopped : .error(error.localizedDescription))
        }
        current = nil
        running = nil
        settle()
        startNext()
    }
}

extension SpeechSpooler {
    /// Play/pause: pauses while speaking, resumes when paused, and when idle queues the last
    /// text again.
    func togglePlayback(_ speech: SpeechEngine) {
        switch speech.state {
        case .speaking: speech.pause()
        case .paused: speech.resume()
        case .idle:
            if let replay = speech.replay {
                submit(SpeechRequest(source: .text(replay.text), mood: replay.mood?.rawValue))
            }
        }
    }
}

// MARK: - The app's face

/// Speaks spooled jobs with the app's face: fetches a page's text, uses the job's voice for that
/// utterance (or the chosen one), floats the face if asked, and closes a face it opened once the
/// queue has been empty for a moment.
final class FacePerformer: SpoolPerformer {
    private let speech: SpeechEngine
    private let settings: FaceWindowSettings
    private var openedFace = false
    private var closing: Task<Void, Never>?

    init(speech: SpeechEngine, settings: FaceWindowSettings) {
        self.speech = speech
        self.settings = settings
    }

    func perform(_ job: SpoolJob, started: @escaping () -> Void) async throws -> SpeechEnd {
        let text: String
        switch job.request.source {
        case .text(let given):
            text = given
        case .url(let url):
            do {
                text = try await WebPage.speakableText(for: url)
            } catch {
                throw SpeechFailure("Can't read \(url.absoluteString): \(error.localizedDescription)")
            }
        }
        if Task.isCancelled { return .stopped }

        closing?.cancel()
        if job.closesFace, Self.faceWindow == nil { openedFace = true }
        settings.keepsOnTopForSpeech = job.alwaysOnTop
        let voice = job.request.voice.map(SpeechEngine.portraitID(forVoice:))
        guard let generation = speech.speak(text, mood: job.request.mood.flatMap(Mood.init(name:)), voice: voice) else {
            throw SpeechFailure("Nothing to speak: the text has no words to say.")
        }
        // A face already showing (for presence, say) isn't brought forward: that would take the
        // keyboard from whoever is typing.
        speech.requestFace(activating: Self.faceWindow == nil)
        started()
        return await speech.end(of: generation)
    }

    func stopCurrent() {
        speech.stop()
    }

    func show(presence: Presence) {
        closing?.cancel()
        if Self.faceWindow == nil {
            openedFace = true
            // Opened quietly: presence follows someone composing elsewhere, so the face must not
            // take the keyboard.
            speech.requestFace(activating: false)
        }
        settings.keepsOnTopForSpeech = true
        speech.show(presence: presence.state, voice: presence.voice.map(SpeechEngine.portraitID(forVoice:)))
    }

    func nod() {
        speech.nod()
    }

    func idle(closingFace: Bool) {
        settings.keepsOnTopForSpeech = false
        speech.show(presence: nil, voice: nil)
        closing?.cancel()
        if closingFace {
            Self.faceWindow?.close()
            openedFace = false
            speech.releaseFace()
            return
        }
        // A moment's grace, in case more speech follows. Then a face opened for the speech closes,
        // still showing the face that spoke, and the menu's chosen face comes back.
        closing = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, speech.state == .idle, SpeechSpooler.shared.current == nil else { return }
            if openedFace {
                Self.faceWindow?.close()
                openedFace = false
            }
            speech.releaseFace()
        }
    }

    /// The face window, if it is showing.
    private static var faceWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(FaceWindow.id) == true && $0.isVisible }
    }
}

// MARK: - The HTTP MCP server's speaker

/// Speaks MCP requests from the HTTP server through the spooler, floating the face.
final class SpoolerSpeaker: Speaker {
    private let spooler: SpeechSpooler

    init(spooler: SpeechSpooler) {
        self.spooler = spooler
    }

    @MainActor func start(_ request: SpeechRequest) async throws -> SpeechHandle {
        let tracker = SpoolerTracker()
        spooler.submit(request, alwaysOnTop: true, closesFace: true) { tracker.receive($0) }
        _ = try await tracker.started()
        return SpeechHandle { try await tracker.end() }
    }

    @MainActor func stop() async {
        spooler.stopAll(closingFace: true)
    }
}

// MARK: - The socket

/// Serves the spooler on its Unix domain socket, for `th` and `th-mcp` (see `Spooler`). Only the
/// menu bar applet runs one. Its socket work runs on its own queue; anything touching the
/// spooler hops to the main actor.
nonisolated final class SpoolerServer: @unchecked Sendable {
    private let path: String
    private let spooler: SpeechSpooler
    private let queue = DispatchQueue(label: "com.sandipchitale.TalkingHead.spooler")
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var nextClient = 0

    init(path: String = Spooler.socketPath, spooler: SpeechSpooler) {
        self.path = path
        self.spooler = spooler
    }

    func start() throws {
        listener = try UnixSocket.listen(at: path)
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        acceptSource = source
        source.resume()
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listener >= 0 {
            Darwin.close(listener)
            listener = -1
        }
        unlink(path)
    }

    private func acceptClient() {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        UnixSocket.noSIGPIPE(fd)
        // Only this user's processes may speak (the socket is 0600 anyway).
        var credentials = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        if getsockopt(fd, 0 /* SOL_LOCAL */, LOCAL_PEERCRED, &credentials, &length) != 0 || credentials.cr_uid != getuid() {
            Darwin.close(fd)
            return
        }
        nextClient += 1
        let client = nextClient
        var lines = LineBuffer()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR || errno == EAGAIN { return }
            guard count > 0 else {
                source.cancel()
                return
            }
            for line in lines.append(Data(chunk[0..<count])) {
                self?.received(line, from: client, fd: fd)
            }
        }
        source.setCancelHandler { [weak self] in
            Darwin.close(fd)
            // The caller went away: its speech and its presence go with it.
            Task { @MainActor in
                self?.spooler.cancelAll(owner: client)
                self?.spooler.dropPresence(owner: client)
            }
        }
        source.resume()
    }

    private func received(_ line: Data, from client: Int, fd: Int32) {
        let send: @Sendable (SpoolerEvent) -> Void = { [queue] event in
            let data = SpoolerCodec.encode(event)
            queue.async { UnixSocket.write(data, to: fd) }
        }
        guard let message = try? SpoolerCodec.decode(SpoolerRequest.self, from: line) else {
            send(.error("Talking Head couldn't understand the request."))
            return
        }
        Task { @MainActor in
            switch message.type {
            case .stop:
                spooler.stopAll(closingFace: true)
                send(.stopped)
            case .presence:
                guard let state = message.state.flatMap(Presence.State.init(rawValue:)) else {
                    send(.error("Unknown presence state \(message.state ?? "(none)"); use listening, thinking or none."))
                    return
                }
                let voice = message.voice.flatMap { SpeechRequest.voices.contains($0) ? $0 : nil }
                spooler.setPresence(owner: client, Presence(state: state, voice: voice), nod: message.pulse == "nod")
                send(.presence)
            case .speak:
                do {
                    let request = try message.speechRequest()
                    spooler.submit(request, owner: client, alwaysOnTop: message.alwaysOnTop ?? false,
                                   closesFace: true) { send($0) }
                } catch let failure as SpeechFailure {
                    send(.error(failure.message))
                } catch {
                    send(.error(error.localizedDescription))
                }
            }
        }
    }
}
