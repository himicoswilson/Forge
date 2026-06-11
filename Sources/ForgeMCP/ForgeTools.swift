import Foundation
import ForgeCore
import MCP

private func textContent(_ text: String) -> Tool.Content {
    .text(text: text, annotations: nil, _meta: nil)
}

/// JSON shape of one service status as returned by `list_services` / `get_service`.
public struct StatusPayload: Codable, Sendable, Equatable {
    public let name: String
    public let port: Int
    public let state: String
    public let pid: Int32?
    public let memoryKB: Int?
    public let uptime: String?

    init(_ status: ServiceStatus) {
        name = status.service.name
        port = status.service.port
        state = status.state.rawValue
        pid = status.pid
        memoryKB = status.memoryKB
        uptime = status.uptime
    }
}

public struct ServiceListPayload: Codable, Sendable, Equatable {
    public let services: [StatusPayload]
}

/// Forge's MCP tool catalog and dispatcher, executing against a `ServiceManager`.
public struct ForgeTools: Sendable {
    public let manager: ServiceManager

    public init(manager: ServiceManager) {
        self.manager = manager
    }

    // MARK: - Catalog

    private static let serviceArg: Value = [
        "type": "object",
        "properties": [
            "service": [
                "type": "string",
                "description": "Service name as declared in .forge/config.json",
            ],
        ],
        "required": ["service"],
    ]

    public static let catalog: [Tool] = [
        Tool(
            name: "list_services",
            description: "Status snapshot of every service in the project: up/starting/down, pid, port, memory, uptime",
            inputSchema: ["type": "object", "properties": [:]],
            annotations: .init(readOnlyHint: true)
        ),
        Tool(
            name: "get_service",
            description: "Status of one service: up/down/starting, pid, port, memory, uptime",
            inputSchema: serviceArg,
            annotations: .init(readOnlyHint: true)
        ),
        Tool(
            name: "get_logs",
            description: "Last N lines from the service's tmux pane",
            inputSchema: [
                "type": "object",
                "properties": [
                    "service": [
                        "type": "string",
                        "description": "Service name as declared in .forge/config.json",
                    ],
                    "lines": [
                        "type": "integer",
                        "description": "Number of log lines to return (default 100)",
                    ],
                ],
                "required": ["service"],
            ],
            annotations: .init(readOnlyHint: true)
        ),
        Tool(
            name: "start_service",
            description: "Launch the service via its start-<name>.sh script in a new tmux session",
            inputSchema: serviceArg
        ),
        Tool(
            name: "stop_service",
            description: "Stop the service by killing its tmux session",
            inputSchema: serviceArg,
            annotations: .init(destructiveHint: true)
        ),
        Tool(
            name: "restart_service",
            description: "Full restart: kill the tmux session, then relaunch the start script",
            inputSchema: serviceArg
        ),
        Tool(
            name: "hotrestart_service",
            description: "Recompile the service's Maven module (mvn compile -pl <module> -am -DskipTests) so Spring DevTools hot-reloads it without a full restart",
            inputSchema: serviceArg
        ),
        Tool(
            name: "warmup",
            description: "Start the core services (gateway, auth, tenant) plus the given module, skipping anything already running",
            inputSchema: [
                "type": "object",
                "properties": [
                    "module": [
                        "type": "string",
                        "description": "Service/module name to warm up alongside the core services",
                    ],
                ],
                "required": ["module"],
            ]
        ),
    ]

    // MARK: - Dispatch

    enum ToolError: Error {
        case badArguments(String)
        case unknownService(String)
    }

    /// Executes one tool call. Shell commands block, so work is moved off the
    /// cooperative thread pool (`mvn compile` can run for a long time).
    public func call(_ name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        guard Self.catalog.contains(where: { $0.name == name }) else {
            throw MCPError.methodNotFound("Unknown tool: \(name)")
        }
        let tools = self
        let args = arguments ?? [:]
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: tools.execute(name, args))
            }
        }
    }

    private func execute(_ name: String, _ args: [String: Value]) -> CallTool.Result {
        do {
            switch name {
            case "list_services":
                let payload = ServiceListPayload(services: manager.statusAll().map(StatusPayload.init))
                return try CallTool.Result(content: [textContent(Self.json(payload))], structuredContent: payload)

            case "get_service":
                let payload = StatusPayload(manager.status(of: try resolveService(args)))
                return try CallTool.Result(content: [textContent(Self.json(payload))], structuredContent: payload)

            case "get_logs":
                let service = try resolveService(args)
                let lines = args["lines"]?.intValue ?? 100
                return .init(content: [textContent(try manager.logs(of: service, lines: lines))])

            case "start_service":
                let service = try resolveService(args)
                try manager.start(service)
                let session = manager.config.sessionName(for: service)
                return .init(content: [textContent(
                    "Started \(service.name) in tmux session '\(session)'. State is 'starting' until port \(service.port) answers."
                )])

            case "stop_service":
                let service = try resolveService(args)
                guard manager.status(of: service).state != .down else {
                    return .init(content: [textContent("\(service.name) is not running — nothing to stop.")])
                }
                try manager.stop(service)
                return .init(content: [textContent("Stopped \(service.name) (killed tmux session '\(manager.config.sessionName(for: service))').")])

            case "restart_service":
                let service = try resolveService(args)
                try manager.restart(service)
                return .init(content: [textContent(
                    "Restarted \(service.name). State is 'starting' until port \(service.port) answers."
                )])

            case "hotrestart_service":
                let service = try resolveService(args)
                try manager.hotRestart(service)
                return .init(content: [textContent(
                    "Compiled module '\(manager.config.module(for: service))' — Spring DevTools will reload \(service.name)."
                )])

            case "warmup":
                guard let module = args["module"]?.stringValue else {
                    throw ToolError.badArguments("Missing required argument 'module'")
                }
                let started = try manager.warmup(module: module)
                let text = started.isEmpty
                    ? "All warm — nothing to start."
                    : "Started: \(started.map(\.name).joined(separator: ", ")). They will report 'starting' until their ports answer."
                return .init(content: [textContent(text)])

            default:
                return .init(content: [textContent("Unknown tool: \(name)")], isError: true)
            }
        } catch {
            return .init(content: [textContent(Self.message(for: error))], isError: true)
        }
    }

    // MARK: - Helpers

    private func resolveService(_ args: [String: Value]) throws -> ServiceConfig {
        guard let name = args["service"]?.stringValue else {
            throw ToolError.badArguments("Missing required argument 'service'")
        }
        guard let service = manager.config.service(named: name) else {
            let known = manager.config.services.map(\.name).joined(separator: ", ")
            throw ToolError.unknownService("Unknown service '\(name)'. Known services: \(known)")
        }
        return service
    }

    private static func message(for error: Error) -> String {
        switch error {
        case ToolError.badArguments(let message), ToolError.unknownService(let message):
            return message
        case CommandError.failed(let command, let exitCode, let stderr):
            return "\(command) failed (exit \(exitCode)): \(stderr)"
        case CommandError.launchFailed(let message):
            return "Failed to launch command: \(message)"
        default:
            return "\(error)"
        }
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(data: try encoder.encode(value), encoding: .utf8) ?? "{}"
    }
}
