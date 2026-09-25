import AVFoundation
import Observation

enum SpeechState {
    case idle, speaking, paused
}

/// UI-facing model: owns the audio pipeline and publishes speech state, mouth opening,
/// and the word currently being spoken.
@Observable
final class SpeechEngine {
    private(set) var state: SpeechState = .idle
    /// Current mouth, morphing smoothly toward the viseme being heard.
    private(set) var mouth = MouthShape.rest
    /// The text of the current utterance.
    private(set) var spokenText = ""
    private(set) var currentWordRange: NSRange?

    /// The faces on offer, each with its own voice, sorted by voice name.
    let portraits = Portrait.all.sorted { $0.voiceName < $1.voiceName }
    var portraitID = Portrait.man.id
    var portrait: Portrait { portraits.first { $0.id == portraitID } ?? .man }
    /// Speech rate, from `AVSpeechUtteranceMinimumSpeechRate` to `AVSpeechUtteranceMaximumSpeechRate`;
    /// the default is a little slower than the system's. Applies from the next utterance.
    var rate: Float = SpeechEngine.rates[1].rate

    /// Speeds offered in the menu.
    static let rates: [(name: String, rate: Float)] = [("Slower", 0.34), ("Normal", 0.42), ("Faster", 0.5)]

    @ObservationIgnored private var pipeline: AudioPipeline!
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init() {
        pipeline = AudioPipeline { [weak self] generation in
            Task { @MainActor in self?.didFinish(generation) }
        }
    }

    func speak(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        spokenText = text
        currentWordRange = nil
        generation = pipeline.speak(text, voice: Self.bestVoice(named: portrait.voiceName), rate: rate)
        state = .speaking
        startTicking()
    }

    func pause() {
        guard state == .speaking else { return }
        pipeline.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        pipeline.resume()
        state = .speaking
        startTicking()
    }

    func stop() {
        pipeline.stop()
        finish()
    }

    /// Play/pause: pauses while speaking, resumes when paused, and replays the last
    /// text when idle.
    func togglePlayback() {
        switch state {
        case .speaking: pause()
        case .paused: resume()
        case .idle: speak(spokenText)
        }
    }

    private func didFinish(_ finished: UInt64) {
        guard finished == generation, state != .idle else { return }
        finish()
    }

    private func finish() {
        state = .idle
        currentWordRange = nil
        ticker?.cancel()
        ticker = nil
        mouth = .rest
    }

    /// Polls the pipeline every frame while speaking and morphs the mouth toward what is heard.
    /// When paused, it lets the mouth settle to rest and then stops polling until resumed.
    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func tick() {
        let snapshot = pipeline.snapshot()
        let current = state == .speaking ? snapshot.viseme : .rest
        // Louder sounds open the mouth a little wider.
        let target = current.shape.opened(by: 0.6 + 0.5 * Self.loudness(forRMS: snapshot.level))
        let next = mouth.interpolated(to: target, amount: 0.45)
        if next.distance(to: mouth) > 0.05 {
            mouth = next
        } else if state != .speaking {
            mouth = target
            ticker?.cancel()
            ticker = nil
        }
        if let word = snapshot.wordRange, word != currentWordRange {
            currentWordRange = word
        }
    }

    /// The highest-quality installed voice with this name.
    private static func bestVoice(named name: String) -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.name == name }
            .max { $0.quality.rawValue < $1.quality.rawValue }
    }

    /// Maps speech RMS (roughly 0 ... 0.25 for system voices) to 0 ... 1.
    private static func loudness(forRMS rms: Float) -> Double {
        let gated = max(0, Double(rms) - 0.01)
        return min(1, pow(gated / 0.2, 0.8))
    }
}
