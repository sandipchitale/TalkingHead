import Foundation

// The small interface between the MCP tools and the two ways of speaking: `th-mcp` runs the `th`
// command (`THProcessSpeaker`), and the menu bar app drives its own face (`AppSpeaker`). The tool
// handlers and definitions are written once, against `Speaker`.

/// What to say, and how.
nonisolated struct SpeechRequest: Sendable, Equatable {
    enum Source: Sendable, Equatable {
        /// Text to speak; it may contain `[mood]` cues.
        case text(String)
        /// A web page to read, or just its text-fragment passage.
        case url(URL)
    }

    var source: Source
    /// `male` or `female`; nil keeps the current voice.
    var voice: String?
    /// One of `moods`; nil lets the text suggest one.
    var mood: String?

    static let voices = ["male", "female"]
    /// Talking Head's moods (the app's `Mood` cases, which a test keeps in step).
    static let moods = ["neutral", "happy", "sad", "surprised", "concerned", "angry"]
}

/// How speech ended.
nonisolated enum SpeechEnd: Sendable, Equatable {
    case finished
    /// Stopped before the end (by `stop`).
    case stopped
}

/// Speech could not be spoken, with a plain sentence saying why, fit to tell the user.
nonisolated struct SpeechFailure: Error, Sendable, Equatable {
    var message: String

    init(_ message: String) {
        self.message = message
    }
}

/// Speech that has started.
nonisolated struct SpeechHandle: Sendable {
    /// Waits for the speech to end. Throws `SpeechFailure` if it failed part-way.
    let finished: @Sendable () async throws -> SpeechEnd
}

/// A way of speaking with the face.
nonisolated protocol Speaker: Sendable {
    /// Shows the face, kept above other windows, and starts speaking. Returns once the voice has
    /// started, or throws `SpeechFailure` if it can't (e.g. the page can't be read).
    func start(_ request: SpeechRequest) async throws -> SpeechHandle
    /// Stops any speech and closes the face.
    func stop() async
}

/// Speaks one request at a time, so two faces never talk over each other: a new request waits
/// for the previous one to finish before it starts. `stop` ends the current speech and drops
/// the requests waiting behind it.
actor SpeechQueue {
    enum Outcome: Sendable, Equatable {
        /// The speech started (for a caller that doesn't wait for the end).
        case started
        case finished
        /// Stopped part-way.
        case stopped
        /// Stopped while waiting its turn, so never spoken.
        case dropped
    }

    private let speaker: any Speaker
    /// Ends when the latest request has been spoken (or failed, or was stopped).
    private var tail: Task<Void, Never>?
    /// Counts `stop` calls; a request queued before a stop is dropped.
    private var stops = 0

    init(speaker: any Speaker) {
        self.speaker = speaker
    }

    /// Speaks `request` after anything already queued. With `wait`, returns when the speech has
    /// ended; otherwise as soon as it starts. Throws `SpeechFailure`.
    func speak(_ request: SpeechRequest, wait: Bool) async throws -> Outcome {
        // Taken before any suspension, so requests keep the order they arrived in.
        let previous = tail
        let ticket = stops
        let start = Task { () async throws -> SpeechHandle? in
            await previous?.value
            return try await self.begin(request, ticket: ticket)
        }
        let run = Task { () async throws -> Outcome in
            guard let handle = try await start.value else { return .dropped }
            return try await handle.finished() == .finished ? .finished : .stopped
        }
        tail = Task { _ = try? await run.value }

        if wait {
            return try await run.value
        }
        return try await start.value == nil ? .dropped : .started
    }

    /// Stops the current speech and drops what is queued.
    func stop() async {
        stops += 1
        await speaker.stop()
    }

    private func begin(_ request: SpeechRequest, ticket: Int) async throws -> SpeechHandle? {
        guard ticket == stops else { return nil }
        return try await speaker.start(request)
    }
}
