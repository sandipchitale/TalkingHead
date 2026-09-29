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
    /// faces should close now).
    func idle(closingFace: Bool)
    /// Someone holds presence: `presences` has one per voice, most recent first. Each face shows
    /// its own between its speeches, opening if need be. With `queueEmpty`, faces with nothing
    /// left to say or show may close.
    func show(presences: [Presence], queueEmpty: Bool)
    /// A one-shot nod by `voice`'s face (nil: the menu's), while it shows presence.
    func nod(voice: String?)
}

/// The one queue for everything the face says: `th` and `th-mcp` (through `SpoolerServer`), the
/// HTTP MCP server, links, the Services menu, and the app's own typing window, file button and
/// Play. Speech is spoken in the order it arrives, one at a time.
///
/// It also keeps the faces' presence (listening, thinking) between speeches, as clients on the
/// socket ask for it. Presence is never queued: a face's speech overrides its presence, and the
/// face returns to it when its speech ends instead of closing. Each voice has its own face, so in
/// a debate one face listens or thinks while the other speaks; the one queue makes them take turns.
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
        if nod, current == nil, presence.current != nil { performer.nod(voice: state.voice) }
    }

    /// Connection `owner` closed: its presence goes with it.
    func dropPresence(owner: Int) {
        presence.drop(owner: owner)
        settle()
    }

    /// Shows the presence being held, one per face, even while speech is under way (the speaking
    /// face ignores its own until it finishes). With nothing held and nothing left to say, lets the
    /// faces go.
    private func settle(closingFace: Bool = false) {
        let queueEmpty = current == nil && queue.isEmpty
        let shown = presence.byVoice
        if !shown.isEmpty {
            performer.show(presences: shown, queueEmpty: queueEmpty)
        } else if queueEmpty {
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

/// Speaks spooled jobs with the app's faces: fetches a page's text, uses the job's voice for that
/// utterance (or the chosen one), floats the face if asked, and closes faces it opened once they
/// have had nothing to say or show for a moment. Each voice has its own face window, so two
/// clients with different voices (a debate's two seats) each get one.
final class FacePerformer: SpoolPerformer {
    private let speech: SpeechEngine
    private let settings: FaceWindowSettings
    /// Faces whose windows this opened (for speech that closes its face, or for presence), to
    /// close again when they have nothing left to say or show.
    private var openedFaces: Set<Portrait.ID> = []
    /// The faces holding presence, as last shown: they stay open.
    private var heldFaces: Set<Portrait.ID> = []
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
        let voice = job.request.voice.map(SpeechEngine.portraitID(forVoice:))
        let portrait = voice ?? speech.portraitID
        let isShowing = FaceWindows.window(for: portrait) != nil
        if job.closesFace, !isShowing { openedFaces.insert(portrait) }
        settings.keepsOnTopForSpeech = job.alwaysOnTop
        guard let generation = speech.speak(text, mood: job.request.mood.flatMap(Mood.init(name:)), voice: voice) else {
            throw SpeechFailure("Nothing to speak: the text has no words to say.")
        }
        // A face opens in front only when none is showing: bringing one forward while another is
        // up (for presence, say) would take the keyboard from whoever is typing.
        if !isShowing { speech.requestFace(portrait, activating: FaceWindows.visible.isEmpty) }
        started()
        return await speech.end(of: generation)
    }

    func stopCurrent() {
        speech.stop()
    }

    func show(presences: [Presence], queueEmpty: Bool) {
        closing?.cancel()
        // Most recent first, so it wins a face that two holders share.
        var shown: [Portrait.ID: Presence.State] = [:]
        for presence in presences {
            let portrait = presence.voice.map(SpeechEngine.portraitID(forVoice:)) ?? speech.portraitID
            if shown[portrait] == nil { shown[portrait] = presence.state }
        }
        heldFaces = Set(shown.keys)
        for portrait in Portrait.all.map(\.id) where shown[portrait] != nil && FaceWindows.window(for: portrait) == nil {
            openedFaces.insert(portrait)
            // Opened quietly: presence follows someone composing elsewhere, so the face must not
            // take the keyboard.
            speech.requestFace(portrait, activating: false)
        }
        settings.keepsOnTopForSpeech = true
        speech.show(presences: shown)
        if queueEmpty { closeFacesSoon() }
    }

    func nod(voice: String?) {
        speech.nod(voice.map(SpeechEngine.portraitID(forVoice:)) ?? speech.portraitID)
    }

    func idle(closingFace: Bool) {
        settings.keepsOnTopForSpeech = false
        heldFaces = []
        speech.show(presences: [:])
        closing?.cancel()
        if closingFace {
            for window in FaceWindows.visible { window.close() }
            openedFaces = []
            speech.releaseFace()
            return
        }
        closeFacesSoon()
    }

    /// After a moment's grace, in case more speech follows, closes the faces this opened that
    /// have nothing to show (each still showing the face that spoke), and the menu's chosen face
    /// comes back.
    private func closeFacesSoon() {
        closing?.cancel()
        closing = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, speech.state == .idle, SpeechSpooler.shared.current == nil else { return }
            for portrait in openedFaces.subtracting(heldFaces) {
                FaceWindows.window(for: portrait)?.close()
                openedFaces.remove(portrait)
            }
            if heldFaces.isEmpty { speech.releaseFace() }
        }
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

