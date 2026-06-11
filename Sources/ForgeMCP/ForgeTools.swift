import Foundation
import ForgeCore
import MCP

private func textContent(_ text: String) -> Tool.Content {
    .text(text: text, annotations: nil, _meta: nil)
}

/// JSON shape of one service status as returned by `list_services` / `get_service`.
public struct StatusPayload: Codable, Sendable, Equatable {
    public let project: String
    public let name: String
    public let port: Int
    public let state: String
    public let pid: Int32?
    public let memoryKB: Int?
    public let uptime: String?

    init(_ status: ServiceStatus, project: String) {
        self.project = project
        name = status.service.name
        port = status.service.port
        state = status.state.rawValue
        pid = status.pid
        memoryKB = status.memoryKB
        uptime = status.uptime
    }
}

public struct ProjectPayload: Codable, Sendable, Equatable {
    public let name: String
    public let root: String
    public let jdk: String?
    public let services: [StatusPayload]
}

public struct WorkspacePayload: Codable, Sendable, Equatable {
    public let projects: [ProjectPayload]
}

/// Forge's MCP tool catalog and dispatcher, executing against all projects
/// registered in the `Workspace`.
public struct ForgeTools: Sendable {
    public let workspace: Workspace

    public init(workspace: Workspace) {
        self.workspace = workspace
    }

    // MARK: - Catalog

    private static let projectProperty: Value = [
        "type": "string",
        "description": "Project name — only needed when the service name exists in more than one registered project",
    ]

    private static let serviceArg: Value = [
        "type": "object",
        "properties": [
            "service": [
                "type": "string",
                "description": "Service name as declared in .forge/config.json",
            ],
            "project": projectProperty,
        ],
        "required": ["service"],
    ]

    public static let catalog: [Tool] = [
        Tool(
            name: "list_services",
            description: "Status snapshot of every service in all registered projects: up/starting/down, pid, port, memory, uptime",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project": [
                        "type": "string",
                        "description": "Limit the snapshot to one project",
                    ],
                ],
            ],
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
                    "project": projectProperty,
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
            description: "Launch the service in a new tmux session (mvn spring-boot:run with the project's JDK)",
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
            description: "Full restart: kill the tmux session, then relaunch",
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
                    "project": projectProperty,
                ],
                "required": ["module"],
            ]
        ),
    ]

    // MARK: - Dispatch

    enum ToolError: Error {
        case badArguments(String)
    }

    /// Executes one tool call. Shell commands block, so work is moved off the
    /// cooperative thread pool (`mvn compile` can run for a long time).
    public func call(_ name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        guard Self.catalog.contains(where: { $0.name == name }) else {
            throw MCPError.methodNotFound("Unknown tool: \(name)")
        }
        let args = arguments ?? [:]
        let projects = await workspace.projects
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: execute(name, args, projects))
            }
        }
    }

    private func execute(_ name: String, _ args: [String: Value], _ projects: [ServiceManager]) -> CallTool.Result {
        do {
            switch name {
            case "list_services":
                let filter = args["project"]?.stringValue
                var scope = projects
                if let filter {
                    guard let manager = projects.first(where: { $0.config.name == filter }) else {
                        throw Workspace.ResolutionError.unknownProject(filter, known: projects.map(\.config.name))
                    }
                    scope = [manager]
                }
                let payload = WorkspacePayload(projects: scope.map { manager in
                    ProjectPayload(
                        name: manager.config.name,
                        root: manager.projectRoot.path,
                        jdk: manager.config.jdk,
                        services: manager.statusAll().map { StatusPayload($0, project: manager.config.name) }
                    )
                })
                return try CallTool.Result(content: [textContent(Self.json(payload))], structuredContent: payload)

            case "get_service":
                let (manager, service) = try resolve(args, in: projects)
                let payload = StatusPayload(manager.status(of: service), project: manager.config.name)
                return try CallTool.Result(content: [textContent(Self.json(payload))], structuredContent: payload)

            case "get_logs":
                let (manager, service) = try resolve(args, in: projects)
                let lines = args["lines"]?.intValue ?? 100
                return .init(content: [textContent(try manager.logs(of: service, lines: lines))])

            case "start_service":
                let (manager, service) = try resolve(args, in: projects)
                try manager.start(service)
                let session = manager.config.sessionName(for: service)
                return .init(content: [textContent(
                    "Started \(manager.config.name)/\(service.name) in tmux session '\(session)'. State is 'starting' until port \(service.port) answers."
                )])

            case "stop_service":
                let (manager, service) = try resolve(args, in: projects)
                guard manager.status(of: service).state != .down else {
                    return .init(content: [textContent("\(manager.config.name)/\(service.name) is not running — nothing to stop.")])
                }
                try manager.stop(service)
                return .init(content: [textContent(
                    "Stopped \(manager.config.name)/\(service.name) (killed tmux session '\(manager.config.sessionName(for: service))')."
                )])

            case "restart_service":
                let (manager, service) = try resolve(args, in: projects)
                try manager.restart(service)
                return .init(content: [textContent(
                    "Restarted \(manager.config.name)/\(service.name). State is 'starting' until port \(service.port) answers."
                )])

            case "hotrestart_service":
                let (manager, service) = try resolve(args, in: projects)
                try manager.hotRestart(service)
                return .init(content: [textContent(
                    "Compiled module '\(manager.config.module(for: service))' — Spring DevTools will reload \(service.name)."
                )])

            case "warmup":
                guard let module = args["module"]?.stringValue else {
                    throw ToolError.badArguments("Missing required argument 'module'")
                }
                let (manager, service) = try Workspace.resolve(in: projects, service: module, project: args["project"]?.stringValue)
                let started = try manager.warmup(module: service.name)
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

    private func resolve(_ args: [String: Value], in projects: [ServiceManager]) throws -> (ServiceManager, ServiceConfig) {
        guard let name = args["service"]?.stringValue else {
            throw ToolError.badArguments("Missing required argument 'service'")
        }
        return try Workspace.resolve(in: projects, service: name, project: args["project"]?.stringValue)
    }

    private static func message(for error: Error) -> String {
        switch error {
        case ToolError.badArguments(let message):
            return message
        case Workspace.ResolutionError.noProjects:
            return "No projects registered — add one in the Forge menu or launch with FORGE_PROJECT set."
        case Workspace.ResolutionError.unknownProject(let name, let known):
            return "Unknown project '\(name)'. Registered projects: \(known.joined(separator: ", "))"
        case Workspace.ResolutionError.unknownService(let name, let available):
            return "Unknown service '\(name)'. Available: \(available.joined(separator: ", "))"
        case Workspace.ResolutionError.ambiguousService(let name, let projects):
            return "Service '\(name)' exists in multiple projects (\(projects.joined(separator: ", "))) — pass the 'project' argument."
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
