import Foundation

/// The app's entry point. A `th` run with something to say first offers it to the menu bar app's
/// spooler, so it waits its turn in the one queue and is spoken by the one face; only when the
/// app isn't running does `th` start its own face (`TalkingHeadApp`).
@main
enum Entry {
    static func main() {
        if let status = Forwarding.forward(LaunchOptions.launch) {
            exit(status)
        }
        TalkingHeadApp.main()
    }
}

/// Hands a `th` run's speech to the running menu bar app, keeping `th`'s contract (which VoiceChat
/// relies on): `th` stays until the speech has finished, exits 0 when it has (or was stopped), and
/// exits 2 with a `th: …` message when it can't be spoken. Killing `th` (SIGTERM, SIGINT) closes
/// its connection, which takes back only its own speech: dropped if waiting, stopped if speaking.
enum Forwarding {
    /// `th`'s exit status, or nil when there is nothing to forward or no app to forward it to.
    static func forward(_ options: LaunchOptions, socketPath: String = Spooler.socketPath) -> Int32? {
        guard let message = request(for: options) else { return nil }
        return forward(message, reportsStart: options.reportsStart, socketPath: socketPath)
    }

    /// Sends `message` and waits for its speech to end (blocking, off the main actor, which the
    /// spooler may need in the same process).
    nonisolated static func forward(_ message: SpoolerRequest, reportsStart: Bool,
                                    socketPath: String = Spooler.socketPath) -> Int32? {
        guard let connection = SpoolerConnection.open(at: socketPath), connection.send(message) else { return nil }
        defer { connection.close() }

        while let event = connection.nextEvent() {
            switch event.type {
            case .queued:
                continue
            case .started:
                if reportsStart {
                    print("started")
                    fflush(stdout)
                }
            case .finished, .stopped:
                return 0
            case .error:
                fail(event.message ?? "couldn't speak")
                return 2
            }
        }
        fail("Talking Head quit before the speech finished")
        return 2
    }

    /// The spooler request for a `th` run that has text or a page to speak. `th` always names its
    /// voice (male unless `-v female`), as it always has.
    static func request(for options: LaunchOptions) -> SpoolerRequest? {
        let source: SpeechRequest.Source
        switch options.mode {
        case .speak(let text): source = .text(text)
        case .speakURL(let url): source = .url(url)
        case .menuBar, .face: return nil
        }
        let request = SpeechRequest(source: source, voice: SpeechEngine.voiceName(of: options.portrait.id),
                                    mood: options.mood?.rawValue)
        return .speak(request, alwaysOnTop: options.alwaysOnTop)
    }

    /// Prints `th: message` the way `th` reports errors ("th: can't read …").
    private nonisolated static func fail(_ message: String) {
        let text = message.prefix(1).lowercased() + message.dropFirst()
        FileHandle.standardError.write(Data("th: \(text)\n".utf8))
    }
}
