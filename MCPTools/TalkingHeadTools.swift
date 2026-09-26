import Foundation
import MCP

/// The MCP tools, `speak`, `speak_url` and `stop`: their definitions and handlers, shared by
/// every transport (`th-mcp` over stdio, the menu bar app over Streamable HTTP) so they can't
/// drift apart.
nonisolated enum TalkingHeadTools {
    static let serverName = "talkinghead"

    static let speakName = "speak"
    static let speakURLName = "speak_url"
    static let stopName = "stop"

    static let speakDescription = """
        Speak text aloud with an animated face on the user's Mac. Use this only when the user asked \
        you to speak, read aloud, or announce something, or when their instructions tell you to announce \
        results. Never speak unprompted, and don't use it during a VoiceChat conversation, which already \
        reads your replies aloud. Write for the ear: short sentences, no Markdown, no code. Summarise; \
        don't read long output verbatim. Set the face's mood for the whole text with `mood`, or change \
        it partway with cues like [happy], [concerned] or [sad] placed before the sentence they apply to.
        """

    static let speakURLDescription = """
        Read a web page aloud with an animated face on the user's Mac: the page's text or, when the \
        URL ends in a text fragment (#:~:text=…), only the passage it points to. Use this only when the \
        user asked you to read a page or passage aloud, or when their instructions tell you to. Never \
        speak unprompted, and don't use it during a VoiceChat conversation, which already reads your \
        replies aloud. Pages are read in their own words, so prefer a text fragment to read just the \
        relevant passage of a long page. Set the face's mood for the whole reading with `mood`.
        """

    static let stopDescription = """
        Stop Talking Head's current speech and close its face. Anything waiting to be spoken is dropped \
        too. Use this when the user asks you to stop or be quiet.
        """

    // MARK: Definitions

    private static let voiceSchema: Value = .object([
        "type": .string("string"),
        "enum": .array(SpeechRequest.voices.map { .string($0) }),
        "description": .string("The voice and face: male (Daniel) or female (Samantha). Omit to keep the current one."),
    ])

    private static let moodSchema: Value = .object([
        "type": .string("string"),
        "enum": .array(SpeechRequest.moods.map { .string($0) }),
        "description": .string("The face's mood for the whole text. Omit to let the text suggest one."),
    ])

    private static let waitSchema: Value = .object([
        "type": .string("boolean"),
        "default": .bool(true),
        "description": .string("true (the default): return when the speech has finished. false: return as soon as it starts. Either way, a later call waits for this speech to finish before speaking."),
    ])

    static let speakTool = Tool(
        name: speakName,
        description: speakDescription,
        inputSchema: .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array([.string("text")]),
            "properties": .object([
                "text": .object([
                    "type": .string("string"),
                    "description": .string("What to say, written for the ear. May contain mood cues such as [happy] before a sentence."),
                ]),
                "voice": voiceSchema,
                "mood": moodSchema,
                "wait": waitSchema,
            ]),
        ]),
        annotations: .init(title: "Speak aloud", readOnlyHint: false, destructiveHint: false,
                           idempotentHint: false, openWorldHint: false)
    )

    static let speakURLTool = Tool(
        name: speakURLName,
        description: speakURLDescription,
        inputSchema: .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array([.string("url")]),
            "properties": .object([
                "url": .object([
                    "type": .string("string"),
                    "description": .string("An http or https address. End it in #:~:text=… to read only that passage."),
                ]),
                "voice": voiceSchema,
                "mood": moodSchema,
                "wait": waitSchema,
            ]),
        ]),
        annotations: .init(title: "Read a web page aloud", readOnlyHint: false, destructiveHint: false,
                           idempotentHint: false, openWorldHint: true)
    )

    static let stopTool = Tool(
        name: stopName,
        description: stopDescription,
        inputSchema: .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([:]),
        ]),
        annotations: .init(title: "Stop speaking", readOnlyHint: false, destructiveHint: false,
                           idempotentHint: false, openWorldHint: false)
    )

    static let tools = [speakTool, speakURLTool, stopTool]

    // MARK: Arguments

    /// The request a `speak` or `speak_url` call asks for, and whether to wait for the end.
    /// Throws `SpeechFailure` with a sentence saying what's wrong.
    static func request(forTool name: String, arguments: [String: Value]?) throws -> (SpeechRequest, wait: Bool) {
        let arguments = arguments ?? [:]
        let source: SpeechRequest.Source
        switch name {
        case speakName:
            guard let value = arguments["text"] else {
                throw SpeechFailure("Nothing to speak: give the words in `text`.")
            }
            guard case .string(let text) = value else { throw SpeechFailure("`text` must be a string.") }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SpeechFailure("Nothing to speak: the text is empty.")
            }
            source = .text(text)
        case speakURLName:
            guard case .string(let string)? = arguments["url"] else {
                throw SpeechFailure("Give the address of the page to read in `url`.")
            }
            guard let url = webURL(string) else {
                throw SpeechFailure("\(string) isn't a web address Talking Head can read. Use an http or https URL.")
            }
            source = .url(url)
        default:
            throw SpeechFailure("Talking Head has no tool called \(name).")
        }

        let voice = try choice("voice", from: SpeechRequest.voices, in: arguments)
        let mood = try choice("mood", from: SpeechRequest.moods, in: arguments)
        var wait = true
        if let value = arguments["wait"] {
            guard case .bool(let flag) = value else { throw SpeechFailure("`wait` must be true or false.") }
            wait = flag
        }
        return (SpeechRequest(source: source, voice: voice, mood: mood), wait)
    }

    /// The optional argument `name`, which must be one of `options` (in any case).
    private static func choice(_ name: String, from options: [String], in arguments: [String: Value]) throws -> String? {
        guard let value = arguments[name] else { return nil }
        guard case .string(let given) = value, let option = options.first(where: { $0 == given.lowercased() }) else {
            let shown = if case .string(let given) = value { "\"\(given)\"" } else { "that" }
            throw SpeechFailure("Unknown \(name) \(shown). Use one of: \(options.joined(separator: ", ")).")
        }
        return option
    }

    /// `string` as an http(s) URL with a host, if it is one.
    static func webURL(_ string: String) -> URL? {
        let string = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host() != nil
        else { return nil }
        return url
    }

    // MARK: Handling calls

    /// Handles a tool call. Failures come back as error results carrying a plain sentence.
    static func call(_ name: String, arguments: [String: Value]?, queue: SpeechQueue) async -> CallTool.Result {
        if name == stopName {
            await queue.stop()
            return CallTool.Result(content: [.text(text: "Stopped speaking and closed the face.")], isError: false)
        }
        do {
            let (request, wait) = try request(forTool: name, arguments: arguments)
            let outcome = try await queue.speak(request, wait: wait)
            return CallTool.Result(content: [.text(text: summary(of: outcome))], isError: false)
        } catch let failure as SpeechFailure {
            return CallTool.Result(content: [.text(text: failure.message)], isError: true)
        } catch {
            return CallTool.Result(content: [.text(text: "Talking Head couldn't speak: \(error.localizedDescription)")],
                                   isError: true)
        }
    }

    static func summary(of outcome: SpeechQueue.Outcome) -> String {
        switch outcome {
        case .started: "Started speaking."
        case .finished: "Finished speaking."
        case .stopped: "Stopped before the end."
        case .dropped: "Not spoken: speech was stopped before its turn came."
        }
    }

    /// Serves the tools on `server`, speaking through `queue`.
    static func register(on server: Server, queue: SpeechQueue) async {
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: tools)
        }
        await server.withMethodHandler(CallTool.self) { params in
            await call(params.name, arguments: params.arguments, queue: queue)
        }
    }
}
