import AppKit

/// Speaks text sent from other apps: the "Speak with Talking Head" service (select text, or a
/// link, in Mail, Safari, …) and `talkinghead://` URLs:
///
///     talkinghead://speak?text=Hello%20there&voice=female&mood=happy
///     talkinghead://speak?url=https%3A%2F%2Fexample.com%2F%23%3A~%3Atext%3DExample
final class ExternalRequests: NSObject {
    /// Set up by the app at launch, before any service or URL request can arrive.
    static var shared: ExternalRequests?

    private let speech: SpeechEngine
    private let spooler: SpeechSpooler

    init(speech: SpeechEngine, spooler: SpeechSpooler) {
        self.speech = speech
        self.spooler = spooler
    }

    /// Starts receiving `talkinghead://` URLs, including the one that launched the app.
    /// Call from `applicationWillFinishLaunching`.
    func registerURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    // MARK: Services

    /// The "Speak with Talking Head" service (`NSMessage` `speakSelection` in Info.plist).
    @objc func speakSelection(_ pasteboard: NSPasteboard, userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        if let string = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !string.isEmpty {
            if let url = Self.webURL(string) {
                speak(url: url)
            } else {
                speak(text: string)
            }
        } else if let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first {
            speak(url: url)
        } else {
            error.pointee = "No text to speak." as NSString
        }
    }

    // MARK: URL scheme

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string)
        else { return }
        open(url)
    }

    /// Handles `talkinghead://speak?text=…` or `?url=…`, with optional `voice=male|female` and
    /// `mood=` (see `Mood`).
    func open(_ url: URL) {
        guard let request = Request(url: url) else {
            showError("Talking Head can't open \(url.absoluteString).")
            return
        }
        // A link's voice is for its own speech; the menu's choice stays as it is.
        let voice = request.portrait.map(SpeechEngine.voiceName(of:))
        switch request.source {
        case .text(let text): speak(text: text, mood: request.mood, voice: voice)
        case .url(let url): speak(url: url, mood: request.mood, voice: voice)
        }
    }

    /// A parsed `talkinghead://` URL.
    nonisolated struct Request: Equatable {
        enum Source: Equatable {
            case text(String)
            case url(URL)
        }

        var source: Source
        var portrait: Portrait.ID?
        /// Unknown moods are ignored, so an old link keeps working.
        var mood: Mood?

        init?(url: URL) {
            guard url.scheme?.lowercased() == "talkinghead",
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            else { return nil }
            func value(_ name: String) -> String? {
                items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let text = value("text"), !text.isEmpty {
                source = .text(text)
            } else if let link = value("url"), let target = ExternalRequests.webURL(link) {
                source = .url(target)
            } else {
                return nil
            }
            // Portrait IDs are their voice names.
            switch value("voice")?.lowercased() {
            case "male": portrait = "Daniel"
            case "female": portrait = "Samantha"
            default: portrait = nil
            }
            mood = value("mood").flatMap(Mood.init(name:))
        }

    }

    // MARK: Speaking

    /// Queued behind any speech already going (see `SpeechSpooler`).
    private func speak(text: String, mood: Mood? = nil, voice: String? = nil) {
        spooler.submit(SpeechRequest(source: .text(text), voice: voice, mood: mood?.rawValue))
        speech.requestFace()
    }

    private func speak(url: URL, mood: Mood? = nil, voice: String? = nil) {
        speech.requestFace()
        spooler.submit(SpeechRequest(source: .url(url), voice: voice, mood: mood?.rawValue)) { [weak self] event in
            if event.type == .error { self?.showError(event.message ?? "Couldn't read \(url.absoluteString).") }
        }
    }

    private func showError(_ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Talking Head"
        alert.informativeText = message
        alert.runModal()
    }

    /// `string` as an http(s) URL, if it is exactly one.
    nonisolated static func webURL(_ string: String) -> URL? {
        guard !string.contains(where: \.isWhitespace),
              let url = URL(string: string),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil
        else { return nil }
        return url
    }
}
