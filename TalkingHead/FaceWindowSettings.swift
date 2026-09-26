import Foundation
import Observation

/// Settings for the face window, shared by its toolbar, the menu bar menu and `th`.
@Observable
final class FaceWindowSettings {
    private static let alwaysOnTopKey = "alwaysOnTop"

    /// Keep the face window (and its speech bubble) above other apps' windows. The menu bar
    /// applet remembers this; a `th` run takes it from `--always-on-top` and doesn't save it.
    var isAlwaysOnTop: Bool {
        didSet {
            if persists { UserDefaults.standard.set(isAlwaysOnTop, forKey: Self.alwaysOnTopKey) }
        }
    }

    /// Keeps the face above other windows while an MCP client is speaking through it, without
    /// changing (or saving) the user's own choice.
    var keepsOnTopForSpeech = false

    /// Whether the face window should float above other windows right now.
    var floats: Bool { isAlwaysOnTop || keepsOnTopForSpeech }

    @ObservationIgnored private let persists: Bool

    init(options: LaunchOptions) {
        persists = !options.isCommandLine
        isAlwaysOnTop = options.isCommandLine
            ? options.alwaysOnTop
            : UserDefaults.standard.bool(forKey: Self.alwaysOnTopKey)
    }
}
