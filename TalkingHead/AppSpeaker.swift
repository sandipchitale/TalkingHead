import AppKit

/// Speaks MCP requests (from the Streamable HTTP server) with the menu bar app's own face,
/// kept above other windows while it speaks. A face it opened closes again shortly after the
/// last speech ends, as a `th` run's does.
@MainActor
final class AppSpeaker: Speaker {
    private let speech: SpeechEngine
    private let settings: FaceWindowSettings
    /// Whether the face was opened for MCP speech (rather than by the user).
    private var openedFace = false
    private var closing: Task<Void, Never>?

    init(speech: SpeechEngine, settings: FaceWindowSettings) {
        self.speech = speech
        self.settings = settings
    }

    @MainActor func start(_ request: SpeechRequest) async throws -> SpeechHandle {
        let text: String
        switch request.source {
        case .text(let given):
            text = given
        case .url(let url):
            do {
                text = try await WebPage.speakableText(for: url)
            } catch {
                throw SpeechFailure("Can't read \(url.absoluteString): \(error.localizedDescription)")
            }
        }

        closing?.cancel()
        let voice = speech.portraitID
        if let requested = request.voice {
            speech.portraitID = requested == "female" ? Portrait.woman.id : Portrait.man.id
        }
        if Self.faceWindow == nil {
            openedFace = true
        }
        settings.keepsOnTopForSpeech = true
        guard let generation = speech.speak(text, mood: request.mood.flatMap(Mood.init(name:))) else {
            finished(restoringVoice: voice)
            throw SpeechFailure("Nothing to speak: the text has no words to say.")
        }
        speech.requestFace()

        return SpeechHandle { [speech] in
            let end = await speech.end(of: generation)
            await self.finished(restoringVoice: voice)
            return end
        }
    }

    @MainActor func stop() async {
        closing?.cancel()
        speech.stop()
        settings.keepsOnTopForSpeech = false
        Self.faceWindow?.close()
        openedFace = false
    }

    /// After MCP speech: unless something else is speaking now, give back the user's voice and
    /// window level, and close a face that was opened for it, after a moment in case more
    /// speech follows.
    private func finished(restoringVoice voice: Portrait.ID) {
        guard speech.state == .idle else { return }
        speech.portraitID = voice
        settings.keepsOnTopForSpeech = false
        guard openedFace else { return }
        closing = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, speech.state == .idle else { return }
            Self.faceWindow?.close()
            openedFace = false
        }
    }

    /// The face window, if it is showing.
    private static var faceWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(FaceWindow.id) == true && $0.isVisible }
    }
}
