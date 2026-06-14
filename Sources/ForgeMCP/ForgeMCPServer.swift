import Foundation
import ForgeCore
import MCP

/// Forge's MCP server: exposes the tool catalog over Streamable HTTP
/// (stateless variant — plain JSON request/response, no sessions) at
/// `http://127.0.0.1:27182/mcp`, using the official MCP Swift SDK.
public actor ForgeMCPServer {
    public static let defaultPort = 27182
    public static let endpoint = "/mcp"
    public static let serverName = "forge"
    public static let serverVersion = "0.2.0"

    private let tools: ForgeTools
    private var router: RequestRouter?
    private var listener: MCPHTTPListener?

    public init(tools: ForgeTools) {
        self.tools = tools
    }

    /// Builds the MCP `Server` with Forge's handlers registered. Used
    /// internally by `start` and directly by tests over `InMemoryTransport`.
    public static func makeServer(tools: ForgeTools) async -> Server {
        let server = Server(
            name: serverName,
            version: serverVersion,
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: ForgeTools.catalog)
        }
        await server.withMethodHandler(CallTool.self) { params in
            try await tools.call(params.name, arguments: params.arguments)
        }
        return server
    }

    /// Starts serving MCP over HTTP. Idempotent — a second call is a no-op.
    public func start(host: String = "127.0.0.1", port: Int = ForgeMCPServer.defaultPort) async throws {
        guard listener == nil else { return }

        let router = RequestRouter(tools: tools)
        try await router.reset()

        let listener = MCPHTTPListener(host: host, port: port, endpoint: Self.endpoint) { request in
            await router.handle(request)
        }
        try await listener.start()

        self.router = router
        self.listener = listener
    }

    /// The actually bound port while running (useful when started with port 0).
    public var boundPort: Int? {
        get async { await listener?.boundPort }
    }

    public func stop() async {
        await listener?.stop()
        await router?.teardown()
        listener = nil
        router = nil
    }
}

// MARK: - Request router

/// Manages the Server+Transport pair, creating a fresh pair whenever an
/// `initialize` request arrives. This avoids the SDK's "Server is already
/// initialized" rejection when a client reconnects (e.g. Claude Code restart).
///
/// Swift actor reentrancy ensures concurrent tool calls are not blocked:
/// while `handleRequest` is suspended waiting for a slow tool, other requests
/// can proceed.
private actor RequestRouter {
    private let tools: ForgeTools
    private var server: Server?
    private var transport: StatelessHTTPServerTransport?

    init(tools: ForgeTools) {
        self.tools = tools
    }

    /// Creates a fresh Server+Transport pair, stopping any previous one first.
    func reset() async throws {
        await server?.stop()
        await transport?.disconnect()
        let t = StatelessHTTPServerTransport()
        let s = await ForgeMCPServer.makeServer(tools: tools)
        try await s.start(transport: t)
        server = s
        transport = t
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        if isInitializeRequest(request) {
            try? await reset()
        }
        guard let transport else {
            return .error(statusCode: 503, .internalError("MCP server not ready"))
        }
        return await transport.handleRequest(request)
    }

    func teardown() async {
        await server?.stop()
        await transport?.disconnect()
        server = nil
        transport = nil
    }

    /// Byte pre-filter: a JSON body whose method is "initialize" must contain
    /// these bytes, so everything else (every tool call) skips the parse.
    private static let initializeMarker = Data("initialize".utf8)

    private func isInitializeRequest(_ request: HTTPRequest) -> Bool {
        guard let body = request.body,
              body.range(of: Self.initializeMarker) != nil,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return false }
        return (json["method"] as? String) == "initialize"
    }
}
