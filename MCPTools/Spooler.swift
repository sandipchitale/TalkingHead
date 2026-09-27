import Foundation
import Synchronization

// The speech spooler: while the menu bar app runs, it owns the face and speaks everyone's speech
// from one first-in, first-out queue. `th` and `th-mcp` hand their speech to it over a Unix domain
// socket (0600, in a 0700 folder) with a tiny newline-delimited JSON protocol:
//
//   → {"type":"speak","text":"Hello","voice":"female","mood":"happy","alwaysOnTop":true}
//   → {"type":"speak","url":"https://example.com/#:~:text=Example"}
//   → {"type":"stop"}                    stops the current speech and clears the whole queue
//   ← {"type":"queued"}  {"type":"started"}  {"type":"finished"}  {"type":"stopped"}
//   ← {"type":"error","message":"Can't read https://example.com/: …"}
//
// A connection carries one `speak`, whose events end with `finished`, `stopped` or `error`
// (a `stop` is answered with `stopped`). Closing the connection early cancels the speech: dropped
// from the queue, or stopped if it is the one speaking.

nonisolated enum Spooler {
    /// ~/Library/Application Support/TalkingHead/speech.sock, or `TALKINGHEAD_SPOOLER_SOCKET`.
    static var socketPath: String {
        if let path = ProcessInfo.processInfo.environment["TALKINGHEAD_SPOOLER_SOCKET"], !path.isEmpty {
            return path
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TalkingHead/speech.sock").path
    }
}

/// A message to the spooler.
nonisolated struct SpoolerRequest: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case speak, stop }

    var type: Kind
    var text: String?
    var url: String?
    var voice: String?
    var mood: String?
    var alwaysOnTop: Bool?

    static let stop = SpoolerRequest(type: .stop)

    static func speak(_ request: SpeechRequest, alwaysOnTop: Bool) -> SpoolerRequest {
        var message = SpoolerRequest(type: .speak, voice: request.voice, mood: request.mood, alwaysOnTop: alwaysOnTop)
        switch request.source {
        case .text(let text): message.text = text
        case .url(let url): message.url = url.absoluteString
        }
        return message
    }

    /// The speech a `speak` message asks for. Throws `SpeechFailure` for a malformed one.
    func speechRequest() throws -> SpeechRequest {
        let source: SpeechRequest.Source
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = .text(text)
        } else if let url {
            guard let web = TalkingHeadTools.webURL(url) else { throw SpeechFailure("Not a web address Talking Head can read: \(url)") }
            source = .url(web)
        } else {
            throw SpeechFailure("Nothing to speak: the text is empty.")
        }
        if let voice, !SpeechRequest.voices.contains(voice) { throw SpeechFailure("Unknown voice \(voice); use male or female") }
        if let mood, !SpeechRequest.moods.contains(mood) {
            throw SpeechFailure("Unknown mood \(mood); use \(SpeechRequest.moods.joined(separator: ", "))")
        }
        return SpeechRequest(source: source, voice: voice, mood: mood)
    }
}

/// A message from the spooler about a `speak`.
nonisolated struct SpoolerEvent: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case queued, started, finished, stopped, error }

    var type: Kind
    var message: String?

    static let queued = SpoolerEvent(type: .queued)
    static let started = SpoolerEvent(type: .started)
    static let finished = SpoolerEvent(type: .finished)
    static let stopped = SpoolerEvent(type: .stopped)
    static func error(_ message: String) -> SpoolerEvent { SpoolerEvent(type: .error, message: message) }

    /// The last event of a `speak`.
    var isFinal: Bool { type != .queued && type != .started }
}

nonisolated enum SpoolerCodec {
    /// One line of JSON, newline included.
    static func encode(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try JSONDecoder().decode(type, from: line)
    }
}

// MARK: - Sockets

nonisolated enum UnixSocket {
    enum Failure: Error { case pathTooLong, socket(Int32), bind(Int32), listen(Int32), alreadyServed }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    private static func withAddress<T>(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// A connected socket, or nil when nothing is listening at `path`.
    static func connect(to path: String) -> Int32? {
        guard var address = try? address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard withAddress(&address, { Darwin.connect(fd, $0, $1) }) == 0 else {
            Darwin.close(fd)
            return nil
        }
        noSIGPIPE(fd)
        return fd
    }

    /// A listening socket at `path`: in a 0700 folder, the socket itself 0600. A stale socket
    /// file is replaced; one that something still answers on is left alone (`alreadyServed`).
    static func listen(at path: String) throws -> Int32 {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(folder, 0o700)
        if let other = connect(to: path) {
            Darwin.close(other)
            throw Failure.alreadyServed
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket(errno) }
        var address = try address(path)
        guard withAddress(&address, { bind(fd, $0, $1) }) == 0 else {
            let error = errno
            Darwin.close(fd)
            throw Failure.bind(error)
        }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else {
            let error = errno
            Darwin.close(fd)
            throw Failure.listen(error)
        }
        return fd
    }

    /// Writing to a closed peer fails with EPIPE instead of killing the process.
    static func noSIGPIPE(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Writes all of `data`; false if the socket is gone.
    @discardableResult
    static func write(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }
}

/// Splits a byte stream into lines.
nonisolated struct LineBuffer: Sendable {
    private var pending = Data()

    /// Adds `data` and returns the complete lines it finished.
    mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }
}

/// A client's connection to the spooler, with blocking reads (for `th`, before its app starts,
/// and for `th-mcp`'s reader threads).
nonisolated final class SpoolerConnection: Sendable {
    private let fd: Int32
    private let state = Mutex<(buffer: LineBuffer, lines: [Data], closed: Bool)>((LineBuffer(), [], false))

    private init(fd: Int32) {
        self.fd = fd
    }

    /// Connects to the spooler, or returns nil when the menu bar app isn't running.
    static func open(at path: String = Spooler.socketPath) -> SpoolerConnection? {
        UnixSocket.connect(to: path).map(SpoolerConnection.init(fd:))
    }

    @discardableResult
    func send(_ request: SpoolerRequest) -> Bool {
        UnixSocket.write(SpoolerCodec.encode(request), to: fd)
    }

    /// The next event, waiting for it; nil once the connection has closed.
    func nextEvent() -> SpoolerEvent? {
        while true {
            let line: Data? = state.withLock { state in
                state.lines.isEmpty ? nil : state.lines.removeFirst()
            }
            if let line {
                if let event = try? SpoolerCodec.decode(SpoolerEvent.self, from: line) { return event }
                continue
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            state.withLock { state in
                state.lines += state.buffer.append(Data(chunk[0..<count]))
            }
        }
    }

    /// Closes the connection, which cancels its speech if that hasn't ended. Wakes a thread
    /// blocked in `nextEvent`.
    func close() {
        let wasOpen = state.withLock { state in
            defer { state.closed = true }
            return !state.closed
        }
        guard wasOpen else { return }
        shutdown(fd, SHUT_RDWR)
    }

    deinit {
        Darwin.close(fd)
    }
}

/// Turns a `speak`'s events into the `Speaker` contract: `started()` waits for the voice to start
/// (or throws), and `end()` waits for the speech to end.
nonisolated final class SpoolerTracker: Sendable {
    private let starts: AsyncStream<Result<Bool, SpeechFailure>>
    private let startInput: AsyncStream<Result<Bool, SpeechFailure>>.Continuation
    private let ends: AsyncStream<Result<SpeechEnd, SpeechFailure>>
    private let endInput: AsyncStream<Result<SpeechEnd, SpeechFailure>>.Continuation

    init() {
        (starts, startInput) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(1))
        (ends, endInput) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(1))
    }

    func receive(_ event: SpoolerEvent) {
        switch event.type {
        case .queued:
            break
        case .started:
            startInput.yield(.success(true))
        case .finished:
            startInput.yield(.success(false))
            endInput.yield(.success(.finished))
        case .stopped:
            startInput.yield(.success(false))
            endInput.yield(.success(.stopped))
        case .error:
            let failure = SpeechFailure(event.message ?? "Talking Head couldn't speak.")
            startInput.yield(.failure(failure))
            endInput.yield(.failure(failure))
        }
        if event.isFinal {
            startInput.finish()
            endInput.finish()
        }
    }

    /// Waits until the voice starts (true) or the speech ends without starting (false).
    func started() async throws -> Bool {
        for await result in starts { return try result.get() }
        return false
    }

    func end() async throws -> SpeechEnd {
        for await result in ends { return try result.get() }
        return .stopped
    }
}

// MARK: - Speaking through the spooler, or without it (th-mcp)

/// The voice chosen in the menu bar app's menu, as it saved it ("male" or "female").
nonisolated enum SavedVoice {
    static let domain = "com.sandipchitale.TalkingHead"
    static let key = "voice"

    static func read() -> String? {
        CFPreferencesAppSynchronize(domain as CFString)
        let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? String
        return value.flatMap { SpeechRequest.voices.contains($0) ? $0 : nil }
    }

    /// The voice to use when a request leaves it out: the app's saved choice, else th's default.
    static func resolve(_ requested: String?, saved: String?) -> String {
        requested ?? saved ?? "male"
    }
}

/// `th-mcp`'s speaker: hands speech to the menu bar app's spooler when the app is running, and
/// otherwise runs `th` itself (with the app's saved voice when none is given, as the spooler
/// would use it).
actor RoutingSpeaker: Speaker {
    private let fallback: THProcessSpeaker
    private let socketPath: String
    private let savedVoice: @Sendable () -> String?
    /// Open spooler connections, closed (cancelling their speech) on shutdown.
    private var connections: [ObjectIdentifier: SpoolerConnection] = [:]

    init(th: URL, socketPath: String = Spooler.socketPath, savedVoice: @escaping @Sendable () -> String? = SavedVoice.read) {
        fallback = THProcessSpeaker(executable: th)
        self.socketPath = socketPath
        self.savedVoice = savedVoice
    }

    func start(_ request: SpeechRequest) async throws -> SpeechHandle {
        if let connection = SpoolerConnection.open(at: socketPath), connection.send(.speak(request, alwaysOnTop: true)) {
            return try await speak(through: connection)
        }
        var request = request
        request.voice = SavedVoice.resolve(request.voice, saved: savedVoice())
        return try await fallback.start(request)
    }

    func stop() async {
        if let connection = SpoolerConnection.open(at: socketPath) {
            connection.send(.stop)
            let reader = Task.detached { connection.nextEvent() }
            _ = await reader.value
            connection.close()
        }
        await fallback.stop()
    }

    /// Cancels this process's speech: closes its spooler connections and ends a running `th`.
    func shutDown() async {
        for connection in connections.values { connection.close() }
        connections.removeAll()
        await fallback.stop()
    }

    private func speak(through connection: SpoolerConnection) async throws -> SpeechHandle {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        let tracker = SpoolerTracker()
        // A plain thread, so its blocking reads don't hold one of the task pool's.
        Thread {
            var ended = false
            while let event = connection.nextEvent() {
                tracker.receive(event)
                if event.isFinal {
                    ended = true
                    break
                }
            }
            if !ended { tracker.receive(.error("Talking Head quit before the speech finished.")) }
            connection.close()
        }.start()

        do {
            _ = try await tracker.started()
        } catch {
            connections[id] = nil
            throw error
        }
        return SpeechHandle { [self] in
            defer { Task { await self.forget(id) } }
            return try await tracker.end()
        }
    }

    private func forget(_ id: ObjectIdentifier) {
        connections[id] = nil
    }
}
