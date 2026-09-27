import Foundation
import MCP

// th-mcp: Talking Head's MCP server over stdio. It serves the tools in `TalkingHeadTools`. While
// the menu bar app runs, it hands speech to the app's spooler, so every caller shares one queue
// and one face; otherwise it runs the `th` command beside it in TalkingHead.app/Contents/MacOS.
//
// Nothing but JSON-RPC may reach standard output: diagnostics go to standard error, and `th`
// runs with its output captured.

func log(_ message: String) {
    FileHandle.standardError.write(Data("[th-mcp] \(message)\n".utf8))
}

/// This executable's folder, following symlinks (e.g. from ~/.local/bin into the app).
let folder = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
    .resolvingSymlinksInPath()
    .deletingLastPathComponent()

let th = folder.appendingPathComponent("th")
guard FileManager.default.isExecutableFile(atPath: th.path) else {
    log("can't find th next to th-mcp (looked for \(th.path)); run th-mcp from TalkingHead.app/Contents/MacOS")
    exit(1)
}

/// The app's version, from the bundle th-mcp lives in.
let appInfo = NSDictionary(contentsOf: folder.deletingLastPathComponent().appendingPathComponent("Info.plist"))
let version = appInfo?["CFBundleShortVersionString"] as? String ?? "0"

let speaker = RoutingSpeaker(th: th)
let queue = SpeechQueue(speaker: speaker)

let server = Server(
    name: TalkingHeadTools.serverName,
    version: version,
    capabilities: .init(tools: .init(listChanged: false))
)
await TalkingHeadTools.register(on: server, queue: queue)

/// Cancels this process's speech (so no face is left talking for it) and exits. Other
/// callers' speech in the spooler carries on.
func shutDown(_ reason: String) async -> Never {
    log("shutting down: \(reason)")
    await speaker.shutDown()
    exit(0)
}

// SIGTERM and SIGINT, like standard input closing, end the session cleanly.
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGTERM, SIGINT] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        Task { await shutDown(signalNumber == SIGTERM ? "SIGTERM" : "SIGINT") }
    }
    source.resume()
    signalSources.append(source)
}

log("serving \(TalkingHeadTools.tools.map(\.name).joined(separator: ", ")) with \(th.path)")
try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
await shutDown("standard input closed")
