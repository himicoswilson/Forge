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

private final class Collector<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int: T] = [:]
    func set(_ value: T, at i: Int) { lock.lock(); defer { lock.unlock() }; storage[i] = value }
    func collect(upTo count: Int) -> [T] { (0..<count).compactMap { storage[$0] } }
}

/// Forge's MCP tool catalog and dispatcher.
public struct ForgeTools: Sendable {
    public let workspace: Workspace

    public init(workspace: Workspace) {
        self.workspace = workspace
    }

    // MARK: - Catalog

    private static let projectArg: Value = [
        "type": "string",
        "description": "Project name — required only when the same service name exists in multiple registered projects",
    ]

    /// Schema for tools that accept one or more service names.
    private static func multiServiceSchema(extra: [String: Value] = [:]) -> Value {
        var props: [String: Value] = [
            "services": [
                "type": "array",
                "items": ["type": "string"],
                "description": "One or more service names as declared in .forge/config.json",
                "minItems": 1,
            ],
            "project": projectArg,
        ]
        for (k, v) in extra { props[k] = v }
        return [
            "type": "object",
            "properties": .object(props),
            "required": ["services"],
        ]
    }

    public static let catalog: [Tool] = [
        Tool(
            name: "list_services",
            description: "Status snapshot of every non-ignored service in all registered projects: up/starting/down, pid, port, memory, uptime",
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
            inputSchema: [
                "type": "object",
                "properties": [
                    "service": [
                        "type": "string",
                        "description": "Service name as declared in .forge/config.json",
                    ],
                    "project": projectArg,
                ],
                "required": ["service"],
            ],
            annotations: .init(readOnlyHint: true)
        ),
        Tool(
            name: "get_logs",
            description: "Last N lines from the service's tmux pane (live scrollback, not the log file)",
            inputSchema: [
                "type": "object",
                "properties": [
                    "service": [
                        "type": "string",
                        "description": "Service name as declared in .forge/config.json",
                    ],
                    "project": projectArg,
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
            description: "Launch one or more services in new tmux sessions. Pass wait: false to fire-and-forget without blocking.",
            inputSchema: multiServiceSchema(extra: [
                "wait": [
                    "type": "boolean",
                    "description": "Wait for the Maven command to complete before returning (default: true). Set false to start in the background immediately.",
                ],
            ])
        ),
        Tool(
            name: "stop_service",
            description: "Stop one or more services by killing their tmux sessions. All stops run in parallel.",
            inputSchema: multiServiceSchema(),
            annotations: .init(destructiveHint: true)
        ),
        Tool(
            name: "restart_service",
            description: "Full restart of one or more services (stop + start). All restarts run in parallel.",
            inputSchema: multiServiceSchema()
        ),
        Tool(
            name: "hotrestart_service",
            description: "Recompile one or more services' Maven modules so Spring DevTools hot-reloads them. All compiles run in parallel.",
            inputSchema: multiServiceSchema()
        ),
    ]

    // MARK: - Dispatch

    enum ToolError: Error {
        case badArguments(String)
    }

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

            // MARK: list_services
            case "list_services":
                let filter = args["project"]?.stringValue
                let scope: [ServiceManager]
                if let filter {
                    guard let m = projects.first(where: { $0.config.name == filter }) else {
                        throw Workspace.ResolutionError.unknownProject(filter, known: projects.map(\.config.name))
                    }
                    scope = [m]
                } else {
                    scope = projects
                }
                let ignored = Self.loadIgnored()
                let pc = Collector<ProjectPayload>()
                DispatchQueue.concurrentPerform(iterations: scope.count) { i in
                    let mgr = scope[i]
                    let excluded = Self.ignoredNames(project: mgr.config.name, in: ignored)
                    let statuses = mgr.statusAll(excluding: excluded)
                    let p = ProjectPayload(
                        name: mgr.config.name,
                        root: mgr.projectRoot.path,
                        jdk: mgr.config.jdk,
                        services: statuses.map { StatusPayload($0, project: mgr.config.name) }
                    )
                    pc.set(p, at: i)
                }
                let payload = WorkspacePayload(projects: pc.collect(upTo: scope.count))
                return try CallTool.Result(content: [textContent(Self.json(payload))], structuredContent: payload)

            // MARK: get_service
            case "get_service":
                let (mgr, svc) = try resolveSingle(args, in: projects)
                let payload = StatusPayload(mgr.status(of: svc), project: mgr.config.name)
                return try CallTool.Result(content: [textContent(Self.json(payload))], structuredContent: payload)

            // MARK: get_logs
            case "get_logs":
                let (mgr, svc) = try resolveSingle(args, in: projects)
                let lines = args["lines"]?.intValue ?? 100
                return .init(content: [textContent(try mgr.logs(of: svc, lines: lines))])

            // MARK: start_service
            case "start_service":
                let pairs = try resolveServices(args, in: projects)
                let wait = args["wait"]?.boolValue ?? true
                if !wait {
                    for (mgr, svc) in pairs {
                        DispatchQueue.global(qos: .userInitiated).async { try? mgr.start(svc) }
                    }
                    let names = pairs.map { "\($0.0.config.name)/\($0.1.name)" }.joined(separator: ", ")
                    return .init(content: [textContent("Queued for startup (not waiting): \(names)")])
                }
                let (lines, hadError) = concurrently(pairs) { mgr, svc in
                    try mgr.start(svc)
                    try mgr.waitForUp(svc)
                    return "Started \(mgr.config.name)/\(svc.name) — UP on port \(svc.port)."
                }
                return .init(content: [textContent(lines.joined(separator: "\n"))], isError: hadError)

            // MARK: stop_service
            case "stop_service":
                let pairs = try resolveServices(args, in: projects)
                let (lines, hadError) = concurrently(pairs) { mgr, svc in
                    guard mgr.status(of: svc).state != .down else {
                        return "\(mgr.config.name)/\(svc.name): not running — nothing to stop."
                    }
                    try mgr.stop(svc)
                    return "Stopped \(mgr.config.name)/\(svc.name)."
                }
                return .init(content: [textContent(lines.joined(separator: "\n"))], isError: hadError)

            // MARK: restart_service
            case "restart_service":
                let pairs = try resolveServices(args, in: projects)
                let (lines, hadError) = concurrently(pairs) { mgr, svc in
                    try mgr.restart(svc)
                    return "Restarted \(mgr.config.name)/\(svc.name) (port \(svc.port) — state 'starting' until UP)."
                }
                return .init(content: [textContent(lines.joined(separator: "\n"))], isError: hadError)

            // MARK: hotrestart_service
            case "hotrestart_service":
                let pairs = try resolveServices(args, in: projects)
                let (lines, hadError) = concurrently(pairs) { mgr, svc in
                    try mgr.hotRestart(svc)
                    return "Compiled '\(mgr.config.module(for: svc))' — Spring DevTools will reload \(mgr.config.name)/\(svc.name)."
                }
                return .init(content: [textContent(lines.joined(separator: "\n"))], isError: hadError)

            default:
                return .init(content: [textContent("Unknown tool: \(name)")], isError: true)
            }
        } catch {
            return .init(content: [textContent(Self.message(for: error))], isError: true)
        }
    }

    // MARK: - Helpers

    /// Resolve a single service from `service` + optional `project` args.
    private func resolveSingle(_ args: [String: Value], in projects: [ServiceManager]) throws -> (ServiceManager, ServiceConfig) {
        guard let name = args["service"]?.stringValue else {
            throw ToolError.badArguments("Missing required argument 'service'")
        }
        return try Workspace.resolve(in: projects, service: name, project: args["project"]?.stringValue)
    }

    /// Resolve one or more services from the `services` array + optional `project` args.
    private func resolveServices(_ args: [String: Value], in projects: [ServiceManager]) throws -> [(ServiceManager, ServiceConfig)] {
        guard let names = args["services"]?.arrayValue?.compactMap({ $0.stringValue }), !names.isEmpty else {
            throw ToolError.badArguments("Missing required argument 'services' (non-empty array of service names)")
        }
        let project = args["project"]?.stringValue
        return try names.map { try Workspace.resolve(in: projects, service: $0, project: project) }
    }

    /// Run `work` for each (manager, service) pair in parallel; collect results or per-service error lines.
    /// Returns per-service result lines plus a flag that's `true` when any operation threw.
    private func concurrently(
        _ pairs: [(ServiceManager, ServiceConfig)],
        _ work: @Sendable (ServiceManager, ServiceConfig) throws -> String
    ) -> (lines: [String], hadError: Bool) {
        let oc = Collector<String>()
        let errc = Collector<Bool>()
        DispatchQueue.concurrentPerform(iterations: pairs.count) { i in
            let (mgr, svc) = pairs[i]
            do {
                oc.set(try work(mgr, svc), at: i)
                errc.set(false, at: i)
            } catch {
                oc.set("\(svc.name): \(Self.message(for: error))", at: i)
                errc.set(true, at: i)
            }
        }
        return (oc.collect(upTo: pairs.count), errc.collect(upTo: pairs.count).contains(true))
    }

    /// Reads ~/.forge/ignored.json → Set of "project/service" keys.
    private static func loadIgnored() -> Set<String> {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".forge/ignored.json")
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(list)
    }

    /// Extracts service names ignored for `project` from the flat ignored set.
    private static func ignoredNames(project: String, in ignored: Set<String>) -> Set<String> {
        let prefix = "\(project)/"
        return Set(ignored.compactMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil })
    }

    private static func message(for error: Error) -> String {
        switch error {
        case ToolError.badArguments(let msg): return msg
        case Workspace.ResolutionError.noProjects:
            return "No projects registered — add one in the Forge menu or set FORGE_PROJECT."
        case Workspace.ResolutionError.unknownProject(let name, let known):
            return "Unknown project '\(name)'. Registered: \(known.joined(separator: ", "))"
        case Workspace.ResolutionError.unknownService(let name, let available):
            return "Unknown service '\(name)'. Available: \(available.joined(separator: ", "))"
        case Workspace.ResolutionError.ambiguousService(let name, let projects):
            return "Service '\(name)' exists in multiple projects (\(projects.joined(separator: ", "))) — pass 'project'."
        case CommandError.failed(let command, let exitCode, let stderr):
            return "\(command) failed (exit \(exitCode)): \(stderr)"
        case CommandError.launchFailed(let message):
            return "Failed to launch: \(message)"
        default: return "\(error)"
        }
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(data: try encoder.encode(value), encoding: .utf8) ?? "{}"
    }
}
