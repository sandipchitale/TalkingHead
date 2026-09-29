import Foundation

/// What the face shows between speeches, as a client asks for it on the spooler socket (see
/// `Spooler`): listening while someone composes, thinking while a model works. Any local client
/// may send it; the app knows nothing about who does.
nonisolated struct Presence: Sendable, Equatable {
    enum State: String, Codable, Sendable, CaseIterable {
        case listening, thinking, none
    }

    var state: State
    /// `male` or `female`: which face shows it. Nil means the menu's choice.
    var voice: String?
}

/// Who holds presence, by spooler connection. The newest message on a connection replaces its
/// last one; `none`, or the connection closing, drops it. When several connections hold presence
/// (two debate seats, say), the most recently updated one is shown.
nonisolated struct PresenceBoard: Sendable, Equatable {
    private struct Holder: Sendable, Equatable {
        var presence: Presence
        var updated: Int
    }

    private var holders: [Int: Holder] = [:]
    private var clock = 0

    /// Records `presence` for connection `owner`; a `none` state removes it.
    mutating func set(owner: Int, _ presence: Presence) {
        guard presence.state != .none else {
            holders[owner] = nil
            return
        }
        clock += 1
        holders[owner] = Holder(presence: presence, updated: clock)
    }

    /// Connection `owner` closed.
    mutating func drop(owner: Int) {
        holders[owner] = nil
    }

    /// The presence to show: the most recently updated holder's, or nil when nobody holds any.
    var current: Presence? {
        holders.values.max { $0.updated < $1.updated }?.presence
    }

    var isEmpty: Bool { holders.isEmpty }
}

/// What the face does, all things considered.
nonisolated enum FaceMode: Sendable, Equatable {
    case speaking
    case listening(voice: String?)
    case thinking(voice: String?)
    case hidden

    /// Speech overrides presence; with neither, the face has nothing to show.
    static func resolve(speaking: Bool, presence: Presence?) -> FaceMode {
        if speaking { return .speaking }
        switch presence?.state {
        case .listening: return .listening(voice: presence?.voice)
        case .thinking: return .thinking(voice: presence?.voice)
        case .some(.none), nil: return .hidden
        }
    }

    /// A face opened for spooled speech or presence closes only when nothing is queued or
    /// speaking and nobody holds presence.
    static func shouldClose(queueEmpty: Bool, presence: Presence?) -> Bool {
        queueEmpty && presence == nil
    }
}
