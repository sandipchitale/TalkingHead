import Foundation
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

/// The MCP tools over Streamable HTTP, served in-process by the menu bar app at
/// `http://127.0.0.1:<port>/mcp`: one MCP `Server` per `Mcp-Session-Id`, all speaking through
/// one `SpeechQueue`, so sessions take turns too.
actor MCPHTTPServer {
    private let app: MCPHTTPApp

    /// Serves on loopback only: `127.0.0.1`, never all interfaces.
    init(port: Int, queue: SpeechQueue, version: String) {
        app = MCPHTTPApp(host: "127.0.0.1", port: port, endpoint: "/mcp") {
            let server = Server(name: TalkingHeadTools.serverName, version: version,
                                capabilities: .init(tools: .init(listChanged: false)))
            await TalkingHeadTools.register(on: server, queue: queue)
            return server
        }
    }

    /// Binds the port (throwing if it's taken) and starts serving in the background.
    func start() async throws {
        try await app.start()
    }

    func stop() async {
        await app.stop()
    }
}

// MARK: - HTTP

// Adapted, like VoiceChat's, from the MCP Swift SDK's reference adapter
// (Sources/MCPConformance/Server/HTTPApp.swift, which can't be imported): sessions by
// `Mcp-Session-Id`, created on `initialize`, closed on DELETE or after an hour idle.

/// Routes HTTP requests to per-session MCP transports.
actor MCPHTTPApp {
    typealias ServerFactory = @Sendable () async throws -> Server

    private struct Session {
        let server: Server
        let transport: StatefulHTTPServerTransport
        var lastAccessedAt: Date
    }

    private let host: String
    private let port: Int
    nonisolated let endpoint: String
    private let makeServer: ServerFactory
    private let sessionTimeout: TimeInterval = 3600
    private var channel: Channel?
    private var group: MultiThreadedEventLoopGroup?
    private var cleanup: Task<Void, Never>?
    private var sessions: [String: Session] = [:]

    init(host: String, port: Int, endpoint: String, makeServer: @escaping ServerFactory) {
        self.host = host
        self.port = port
        self.endpoint = endpoint
        self.makeServer = makeServer
    }

    /// Binds and starts accepting connections, then returns; NIO's event loop keeps serving.
    /// Throws if the port can't be bound (e.g. it's taken).
    func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(MCPHTTPHandler(app: self))
                }
            }
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
        do {
            channel = try await bootstrap.bind(host: host, port: port).get()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
        self.group = group
        cleanup = Task { await closeIdleSessions() }
    }

    /// Closes every session and the listener, so a later `start` begins afresh.
    func stop() async {
        for id in sessions.keys { await closeSession(id) }
        cleanup?.cancel()
        cleanup = nil
        try? await channel?.close()
        channel = nil
        try? await group?.shutdownGracefully()
        group = nil
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = request.header(HTTPHeaderName.sessionID)
        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            sessions[sessionID] = session
            let response = await session.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE", response.statusCode == 200 {
                await closeSession(sessionID)
            }
            return response
        }
        if request.method.uppercased() == "POST", let body = request.body, Self.isInitialize(body) {
            return await createSession(for: request)
        }
        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Not Found: Session not found or expired"))
        }
        return .error(statusCode: 400, .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header"))
    }

    private static func isInitialize(_ body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return json["method"] as? String == "initialize"
    }

    private nonisolated struct FixedSessionID: SessionIDGenerator {
        let id: String
        func generateSessionID() -> String { id }
    }

    private func createSession(for request: HTTPRequest) async -> HTTPResponse {
        let id = UUID().uuidString
        let transport = StatefulHTTPServerTransport(sessionIDGenerator: FixedSessionID(id: id))
        do {
            let server = try await makeServer()
            try await server.start(transport: transport)
            sessions[id] = Session(server: server, transport: transport, lastAccessedAt: Date())
            let response = await transport.handleRequest(request)
            if case .error = response { await closeSession(id) }
            return response
        } catch {
            await transport.disconnect()
            return .error(statusCode: 500, .internalError("Failed to create session: \(error.localizedDescription)"))
        }
    }

    private func closeSession(_ id: String) async {
        guard let session = sessions.removeValue(forKey: id) else { return }
        await session.server.stop()
        await session.transport.disconnect()
    }

    private func closeIdleSessions() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            let now = Date()
            for (id, session) in sessions where now.timeIntervalSince(session.lastAccessedAt) > sessionTimeout {
                await closeSession(id)
            }
        }
    }
}

/// Converts between NIO's HTTP parts and the SDK's `HTTPRequest`/`HTTPResponse`.
private nonisolated final class MCPHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let app: MCPHTTPApp
    private var head: HTTPRequestHead?
    private var body: ByteBuffer?

    init(app: MCPHTTPApp) {
        self.app = app
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let requestHead):
            head = requestHead
            body = context.channel.allocator.buffer(capacity: 0)
        case .body(var buffer):
            body?.writeBuffer(&buffer)
        case .end:
            guard let head else { return }
            let body = self.body
            self.head = nil
            self.body = nil
            nonisolated(unsafe) let context = context
            Task { await self.respond(to: head, body: body, context: context) }
        }
    }

    private func respond(to head: HTTPRequestHead, body: ByteBuffer?, context: ChannelHandlerContext) async {
        let path = String(head.uri.split(separator: "?").first ?? Substring(head.uri))
        let response: HTTPResponse
        if path == app.endpoint {
            var headers: [String: String] = [:]
            for (name, value) in head.headers {
                headers[name] = headers[name].map { $0 + ", " + value } ?? value
            }
            let data = body.flatMap { $0.readableBytes > 0 ? $0.getBytes(at: 0, length: $0.readableBytes) : nil }.map { Data($0) }
            response = await app.handle(HTTPRequest(method: head.method.rawValue, headers: headers, body: data, path: path))
        } else {
            response = .error(statusCode: 404, .invalidRequest("Not Found"))
        }
        await write(response, version: head.version, context: context)
    }

    private func write(_ response: HTTPResponse, version: HTTPVersion, context: ChannelHandlerContext) async {
        nonisolated(unsafe) let context = context
        let loop = context.eventLoop
        var responseHead = HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: response.statusCode))
        for (name, value) in response.headers { responseHead.headers.add(name: name, value: value) }
        let head = responseHead

        if case .stream(let stream, _) = response {
            loop.execute {
                context.writeAndFlush(self.wrapOutboundOut(.head(head)), promise: nil)
            }
            do {
                for try await chunk in stream {
                    loop.execute {
                        var buffer = context.channel.allocator.buffer(capacity: chunk.count)
                        buffer.writeBytes(chunk)
                        context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    }
                }
            } catch {
                // The stream ended with an error; end the response.
            }
            loop.execute {
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
            return
        }

        let bodyData = response.bodyData
        loop.execute {
            context.write(self.wrapOutboundOut(.head(head)), promise: nil)
            if let bodyData {
                var buffer = context.channel.allocator.buffer(capacity: bodyData.count)
                buffer.writeBytes(bodyData)
                context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            }
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}
