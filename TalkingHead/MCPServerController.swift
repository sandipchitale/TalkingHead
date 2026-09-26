import AppKit
import Observation

/// Turns the menu bar app's Streamable HTTP MCP server on and off. It's off by default; the
/// menu item "MCP Server (port 8766)" turns it on and is remembered between launches, and
/// `TALKINGHEAD_MCP_HTTP_PORT` turns it on at launch with that port.
///
/// Only the menu bar applet has one (`shared` is nil in a `th` run), so an instance started by
/// `th` never opens the port.
@Observable
final class MCPServerController {
    static var shared: MCPServerController?

    static let defaultPort = 8766
    private static let enabledKey = "mcpHTTPServerEnabled"
    private static let portVariable = "TALKINGHEAD_MCP_HTTP_PORT"

    /// The port from `TALKINGHEAD_MCP_HTTP_PORT`, if that is set to one.
    private static var environmentPort: Int? {
        ProcessInfo.processInfo.environment[portVariable].flatMap(Int.init).flatMap { (1...65535).contains($0) ? $0 : nil }
    }

    /// The port the server uses: `TALKINGHEAD_MCP_HTTP_PORT`, or 8766.
    static var configuredPort: Int { environmentPort ?? defaultPort }

    let port = MCPServerController.configuredPort
    private(set) var isRunning = false

    @ObservationIgnored private let queue: SpeechQueue
    @ObservationIgnored private var server: MCPHTTPServer?

    init(speech: SpeechEngine, faceSettings: FaceWindowSettings) {
        queue = SpeechQueue(speaker: AppSpeaker(speech: speech, settings: faceSettings))
    }

    /// Starts the server if the user left it on, or the environment asks for it.
    func startAtLaunch() {
        if UserDefaults.standard.bool(forKey: Self.enabledKey) || Self.environmentPort != nil {
            start()
        }
    }

    /// The menu item: turns the server on or off, and remembers the choice.
    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled { start() } else { stop() }
    }

    func stop() {
        guard let server else { return }
        self.server = nil
        isRunning = false
        Task { await server.stop() }
    }

    private func start() {
        guard server == nil else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let candidate = MCPHTTPServer(port: port, queue: queue, version: version)
        server = candidate
        isRunning = true
        Task {
            do {
                try await candidate.start()
                NSLog("Talking Head MCP server listening on http://127.0.0.1:\(port)/mcp")
            } catch {
                guard server === candidate else { return }
                server = nil
                isRunning = false
                UserDefaults.standard.set(false, forKey: Self.enabledKey)
                showFailure(error)
            }
        }
    }

    private func showFailure(_ error: Error) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Couldn't start the MCP server"
        alert.informativeText = """
            Port \(port): \(error.localizedDescription)

            Another program may be using this port. Free it and try again, or set \
            \(Self.portVariable) to another port before launching Talking Head.
            """
        alert.runModal()
    }
}
