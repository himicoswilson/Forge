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
    private var server: Server?
    private var transport: StatelessHTTPServerTransport?
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

        let transport = StatelessHTTPServerTransport()
        let server = await Self.makeServer(tools: tools)
        try await server.start(transport: transport)

        let listener = MCPHTTPListener(host: host, port: port, endpoint: Self.endpoint) { request in
            await transport.handleRequest(request)
        }
        try await listener.start()

        self.server = server
        self.transport = transport
        self.listener = listener
    }

    /// The actually bound port while running (useful when started with port 0).
    public var boundPort: Int? {
        get async { await listener?.boundPort }
    }

    public func stop() async {
        await listener?.stop()
        await server?.stop()
        await transport?.disconnect()
        listener = nil
        server = nil
        transport = nil
    }
}
