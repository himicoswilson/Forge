import Foundation
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

/// Minimal NIO HTTP/1.1 listener that forwards requests on one endpoint to an
/// async handler (the MCP server transport). Adapted from the official
/// swift-sdk conformance server's HTTPApp.
actor MCPHTTPListener {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let host: String
    private let port: Int
    private let endpoint: String
    private let handler: Handler
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?

    init(host: String, port: Int, endpoint: String, handler: @escaping Handler) {
        self.host = host
        self.port = port
        self.endpoint = endpoint
        self.handler = handler
    }

    /// Binds the socket and starts accepting connections. Returns once listening.
    func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.group = group
        let endpoint = self.endpoint
        let handler = self.handler

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPHandler(endpoint: endpoint, handler: handler))
                }
            }
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

        channel = try await bootstrap.bind(host: host, port: port).get()
    }

    /// The actually bound port (useful when started with port 0).
    var boundPort: Int? {
        channel?.localAddress?.port
    }

    func stop() async {
        if let channel {
            try? await channel.close()
        }
        if let group {
            try? await group.shutdownGracefully()
        }
        channel = nil
        group = nil
    }
}

/// Thin NIO adapter converting between NIO HTTP types and the framework-agnostic
/// `HTTPRequest`/`HTTPResponse` the MCP transport consumes.
private final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let endpoint: String
    private let handler: MCPHTTPListener.Handler

    private struct RequestState {
        var head: HTTPRequestHead
        var bodyBuffer: ByteBuffer
    }

    private var requestState: RequestState?

    init(endpoint: String, handler: @escaping MCPHTTPListener.Handler) {
        self.endpoint = endpoint
        self.handler = handler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            requestState = RequestState(
                head: head,
                bodyBuffer: context.channel.allocator.buffer(capacity: 0)
            )
        case .body(var buffer):
            requestState?.bodyBuffer.writeBuffer(&buffer)
        case .end:
            guard let state = requestState else { return }
            requestState = nil

            nonisolated(unsafe) let ctx = context
            Task { @MainActor in
                await self.handleRequest(state: state, context: ctx)
            }
        }
    }

    private func handleRequest(state: RequestState, context: ChannelHandlerContext) async {
        let head = state.head
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri

        guard path == endpoint else {
            await writeResponse(
                .error(statusCode: 404, .invalidRequest("Not Found")),
                version: head.version,
                context: context
            )
            return
        }

        let response = await handler(makeHTTPRequest(from: state))
        await writeResponse(response, version: head.version, context: context)
    }

    private func makeHTTPRequest(from state: RequestState) -> HTTPRequest {
        // Combine multiple header values per RFC 7230
        var headers: [String: String] = [:]
        for (name, value) in state.head.headers {
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        let body: Data?
        if state.bodyBuffer.readableBytes > 0,
            let bytes = state.bodyBuffer.getBytes(at: 0, length: state.bodyBuffer.readableBytes)
        {
            body = Data(bytes)
        } else {
            body = nil
        }

        let path = String(state.head.uri.split(separator: "?").first ?? Substring(state.head.uri))

        return HTTPRequest(
            method: state.head.method.rawValue,
            headers: headers,
            body: body,
            path: path
        )
    }

    private func writeResponse(
        _ response: HTTPResponse,
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) async {
        nonisolated(unsafe) let ctx = context
        let eventLoop = ctx.eventLoop
        let statusCode = response.statusCode
        let headers = response.headers

        switch response {
        case .stream(let stream, _):
            eventLoop.execute {
                var head = HTTPResponseHead(
                    version: version,
                    status: HTTPResponseStatus(statusCode: statusCode)
                )
                for (name, value) in headers {
                    head.headers.add(name: name, value: value)
                }
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
                ctx.flush()
            }

            do {
                for try await chunk in stream {
                    eventLoop.execute {
                        var buffer = ctx.channel.allocator.buffer(capacity: chunk.count)
                        buffer.writeBytes(chunk)
                        ctx.writeAndFlush(
                            self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    }
                }
            } catch {
                // Stream ended with error — fall through and end the response
            }

            eventLoop.execute {
                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }

        default:
            let bodyData = response.bodyData
            eventLoop.execute {
                var head = HTTPResponseHead(
                    version: version,
                    status: HTTPResponseStatus(statusCode: statusCode)
                )
                for (name, value) in headers {
                    head.headers.add(name: name, value: value)
                }

                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)

                if let body = bodyData {
                    var buffer = ctx.channel.allocator.buffer(capacity: body.count)
                    buffer.writeBytes(body)
                    ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                }

                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}
