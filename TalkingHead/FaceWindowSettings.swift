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

    @ObservationIgnored private let persists: Bool

    init(options: LaunchOptions) {
        persists = !options.isCommandLine
        isAlwaysOnTop = options.isCommandLine
            ? options.alwaysOnTop
            : UserDefaults.standard.bool(forKey: Self.alwaysOnTopKey)
    }
}
