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
    /// The text of the current utterance, without mood cues and mood emoji.
    private(set) var spokenText = ""
    private(set) var currentWordRange: NSRange?
    /// How far the eyebrows are raised (1, or higher for "?" and "!") or lowered (negative), 0
    /// at rest; they go up on stressed words and down a little on negative or doubtful ones.
    private(set) var brows = 0.0
    /// The mood being shown, easing from one to the next (see `Mood`).
    private(set) var expression = FaceExpression.neutral

    /// The faces on offer, each with its own voice, sorted by voice name.
    let portraits = Portrait.all.sorted { $0.voiceName < $1.voiceName }
    var portraitID = Portrait.man.id
    var portrait: Portrait { portraits.first { $0.id == portraitID } ?? .man }
    /// Incremented to ask for the face window to be shown (e.g. when another app sends text);
    /// the menu bar item's view, which can open windows, reacts to it.
    private(set) var faceRequests = 0

    /// Speech rate, from `AVSpeechUtteranceMinimumSpeechRate` to `AVSpeechUtteranceMaximumSpeechRate`;
    /// the default is a little slower than the system's. Applies from the next utterance.
    var rate: Float = SpeechEngine.rates[1].rate

    /// Speeds offered in the menu.
    static let rates: [(name: String, rate: Float)] = [("Slower", 0.34), ("Normal", 0.42), ("Faster", 0.5)]

    @ObservationIgnored private var pipeline: AudioPipeline!
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// Where the eyebrows are held, until when, and when they may next move, so they don't
    /// twitch on every other word.
    @ObservationIgnored private var browHold = 0.0
    @ObservationIgnored private var browHoldUntil = ContinuousClock.now
    @ObservationIgnored private var nextBrowMove = ContinuousClock.now
    /// The text being spoken with its moods, and the mood for the words being heard.
    @ObservationIgnored private var script = Script(text: "")
    @ObservationIgnored private var mood = Mood.neutral
    /// What was last asked for, to replay: the text as given, cues and all, and its mood.
    @ObservationIgnored private var lastRequest: (text: String, mood: Mood?) = ("", nil)
    /// Callers waiting for an utterance (by generation) to end; see `end(of:)`.
    @ObservationIgnored private var endWaiters: [(generation: UInt64, continuation: CheckedContinuation<SpeechEnd, Never>)] = []
    /// How the last utterance to end ended.
    @ObservationIgnored private var lastEnd: (generation: UInt64, end: SpeechEnd)?

    init() {
        pipeline = AudioPipeline { [weak self] generation in
            Task { @MainActor in self?.didFinish(generation) }
        }
    }

    /// Speaks `text`, showing `mood` throughout unless the text's own `[mood]` cues say
    /// otherwise; with no mood, the text's emoji and feeling words suggest one (see `Script`).
    /// Returns the utterance's generation, to wait for its end with `end(of:)`, or nil when
    /// there is nothing to say.
    @discardableResult
    func speak(_ text: String, mood: Mood? = nil) -> UInt64? {
        let script = Script.parse(text.trimmingCharacters(in: .whitespacesAndNewlines), mood: mood)
        let spoken = script.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return nil }
        // Speaking over an utterance cuts it short.
        if state != .idle { ended(.stopped) }
        lastRequest = (text, mood)
        self.script = script
        self.mood = script.mood(at: 0)
        spokenText = script.text
        currentWordRange = nil
        generation = pipeline.speak(script.text, voice: Self.bestVoice(named: portrait.voiceName), rate: rate)
        state = .speaking
        startTicking()
        return generation
    }

    /// Waits for the utterance `generation` (from `speak`) to end: finished, or stopped (by
    /// `stop`, or by speaking something else).
    func end(of generation: UInt64) async -> SpeechEnd {
        if generation == self.generation, state != .idle {
            return await withCheckedContinuation { endWaiters.append((generation, $0)) }
        }
        if let lastEnd, lastEnd.generation == generation { return lastEnd.end }
        return .stopped
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
        if state != .idle { ended(.stopped) }
        pipeline.stop()
        finish()
    }

    func requestFace() {
        faceRequests += 1
    }

    /// Play/pause: pauses while speaking, resumes when paused, and replays the last
    /// text when idle.
    func togglePlayback() {
        switch state {
        case .speaking: pause()
        case .paused: resume()
        case .idle: speak(lastRequest.text, mood: lastRequest.mood)
        }
    }

    private func didFinish(_ finished: UInt64) {
        guard finished == generation, state != .idle else { return }
        ended(.finished)
        finish()
    }

    /// Records how the current utterance ended and tells those waiting for it.
    private func ended(_ end: SpeechEnd) {
        lastEnd = (generation, end)
        let waiting = endWaiters.filter { $0.generation == generation }
        endWaiters.removeAll { $0.generation == generation }
        for waiter in waiting { waiter.continuation.resume(returning: end) }
    }

    private func finish() {
        state = .idle
        currentWordRange = nil
        // The ticker keeps running until the mouth and brows have settled.
        if ticker == nil { startTicking() }
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
        let mouthMoving = next.distance(to: mouth) > 0.05
        mouth = mouthMoving ? next : target

        let now = ContinuousClock.now
        if state == .speaking, let word = snapshot.wordRange, word != currentWordRange {
            currentWordRange = word
            mood = script.mood(at: word.location)
            // The voice's own stress on the word, once its audio has been rendered.
            let accent = pipeline.prosody(ofWordAt: word)?.accent
            // The end of a question or exclamation always gets its raise, even hard on the
            // heels of another move.
            if let hold = Emphasis.brows(for: word, in: spokenText, accent: accent),
               now >= nextBrowMove || hold >= Emphasis.exclaimedLift {
                browHold = hold
                // A frown or a big raise lingers a little longer than a plain raise.
                browHoldUntil = now + .milliseconds(hold > 0 && hold < Emphasis.exclaimedLift ? 420 : 550)
                nextBrowMove = now + .milliseconds(800)
            }
        }
        // Away from rest quickly, back slowly.
        let browTarget = state == .speaking && now < browHoldUntil ? browHold : 0
        brows = Self.approach(brows, browTarget, rate: abs(browTarget) > abs(brows) ? 0.25 : 0.08)
        // The mood holds through a pause and fades once the speech is over.
        let expressionTarget = state == .idle ? FaceExpression.neutral : mood.face
        expression = expression.approaching(expressionTarget, rate: 0.06)

        if state != .speaking, !mouthMoving, brows == 0, expression == expressionTarget {
            ticker?.cancel()
            ticker = nil
        }
    }

    /// Moves `value` a fraction of the way to `target`, snapping to it when close.
    private static func approach(_ value: Double, _ target: Double, rate: Double) -> Double {
        let next = value + (target - value) * rate
        return abs(next - target) < 0.005 ? target : next
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
