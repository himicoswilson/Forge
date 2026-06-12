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
    /// How long the service has been in `starting` (e.g. "00:42"), nil otherwise.
    public let startingFor: String?

    init(_ status: ServiceStatus, project: String) {
        self.project = project
        name = status.service.name
        port = status.service.port
        state = status.state.rawValue
        pid = status.pid
        memoryKB = status.memoryKB
        uptime = status.uptime
        startingFor = status.startingFor
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

    private static func waitArg(_ description: String) -> Value {
        ["type": "boolean", "description": .string(description)]
    }

    private static let timeoutArg: Value = [
        "type": "integer",
        "description": "Seconds to wait for UP before failing with the recent log tail attached (default 180)",
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
            description: "Status snapshot of every non-ignored service in all registered projects: up/starting/down, pid, port, memory, uptime, and startingFor (how long a starting service has been starting)",
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
            description: "Service log, tail or regex search. Reads the durable log file (~/.forge/logs/<session>.log — full history since start, no line wrapping), falling back to the tmux pane scrollback. Combine pattern + context to jump straight to exception stacks instead of paging through a plain tail.",
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
                        "description": "Maximum lines to return, keeping the most recent (default 100)",
                    ],
                    "pattern": [
                        "type": "string",
                        "description": "Regex — return only matching lines (e.g. \"Exception|ERROR\") instead of a plain tail",
                    ],
                    "context": [
                        "type": "integer",
                        "description": "With pattern: also include N lines around each match, like grep -C (default 0)",
                    ],
                    "since": [
                        "type": "string",
                        "description": "Only entries from the last N seconds/minutes/hours — \"30s\", \"5m\", \"2h\" — judged by log line timestamps",
                    ],
                ],
                "required": ["service"],
            ],
            annotations: .init(readOnlyHint: true)
        ),
        Tool(
            name: "start_service",
            description: "Start one or more services in tmux sessions. Idempotent: services already up or starting are skipped (never an error), stale dead sessions are cleared first. By default blocks until every started/starting service reports UP.",
            inputSchema: multiServiceSchema(extra: [
                "wait": waitArg("Wait until each service reports UP before returning (default: true). Set false to fire-and-forget."),
                "timeoutSeconds": timeoutArg,
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
            description: "Full restart of one or more services (stop + start), in parallel. By default blocks until each service reports UP; on timeout the error includes the recent log tail.",
            inputSchema: multiServiceSchema(extra: [
                "wait": waitArg("Wait until each restarted service reports UP before returning (default: true). Set false to return as soon as the restart is issued."),
                "timeoutSeconds": timeoutArg,
            ])
        ),
        Tool(
            name: "hotrestart_service",
            description: "Recompile one or more services' Maven modules so Spring DevTools hot-reloads them, then confirm each service reports UP again. All compiles run in parallel.",
            inputSchema: multiServiceSchema(extra: [
                "wait": waitArg("After compiling, wait until the service reports UP again (default: true). Set false to skip the confirmation."),
                "timeoutSeconds": timeoutArg,
            ])
        ),
    ]

    // MARK: - Dispatch

    enum ToolError: Error {
        case badArguments(String)
        /// Operation failed; message is already fully formatted (may embed a log tail).
        case failed(String)
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
                let output = try mgr.logs(
                    of: svc,
                    lines: args["lines"]?.intValue ?? 100,
                    pattern: args["pattern"]?.stringValue,
                    context: args["context"]?.intValue ?? 0,
                    since: args["since"]?.stringValue.map(LogFilter.parseDuration)
                )
                return .init(content: [textContent(output.isEmpty ? "(no matching log lines)" : output)])

            // MARK: start_service
            case "start_service":
                let pairs = try resolveServices(args, in: projects)
                let wait = args["wait"]?.boolValue ?? true
                let timeout = args["timeoutSeconds"]?.intValue ?? 180
                let (lines, hadError) = concurrently(pairs) { mgr, svc in
                    let label = "\(mgr.config.name)/\(svc.name)"
                    switch try mgr.startIfNeeded(svc) {
                    case .alreadyUp:
                        return "\(label): skipped — already up."
                    case .alreadyStarting:
                        guard wait else { return "\(label): skipped — already starting." }
                        try waitForUpAttachingLogs(mgr, svc, timeout: timeout)
                        return "\(label): already starting — waited until UP on port \(svc.port)."
                    case .started:
                        guard wait else { return "\(label): started (not waiting)." }
                        try waitForUpAttachingLogs(mgr, svc, timeout: timeout)
                        return "\(label): started — UP on port \(svc.port)."
                    }
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
                let wait = args["wait"]?.boolValue ?? true
                let timeout = args["timeoutSeconds"]?.intValue ?? 180
                let (lines, hadError) = concurrently(pairs) { mgr, svc in
                    let label = "\(mgr.config.name)/\(svc.name)"
                    try mgr.restart(svc)
                    guard wait else { return "\(label): restarted (not waiting — state 'starting' until UP)." }
                    try waitForUpAttachingLogs(mgr, svc, timeout: timeout)
                    return "\(label): restarted — UP on port \(svc.port)."
                }
                return .init(content: [textContent(lines.joined(separator: "\n"))], isError: hadError)

            // MARK: hotrestart_service
            case "hotrestart_service":
                let pairs = try resolveServices(args, in: projects)
                let wait = args["wait"]?.boolValue ?? true
                let timeout = args["timeoutSeconds"]?.intValue ?? 180
                let (lines, hadError) = concurrently(pairs) { mgr, svc in
                    let label = "\(mgr.config.name)/\(svc.name)"
                    let module = mgr.config.module(for: svc)
                    try mgr.hotRestart(svc)
                    guard wait else { return "Compiled '\(module)' — Spring DevTools will reload \(label)." }
                    guard mgr.status(of: svc).state != .down else {
                        return "Compiled '\(module)', but \(label) is not running — nothing to reload."
                    }
                    try waitForUpAttachingLogs(mgr, svc, timeout: timeout)
                    return "Compiled '\(module)' — \(label) reloaded, UP on port \(svc.port)."
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

    /// Block until `svc` reports UP; on failure rethrow with the last 40 log
    /// lines attached, saving the caller a follow-up `get_logs` round trip.
    private func waitForUpAttachingLogs(_ mgr: ServiceManager, _ svc: ServiceConfig, timeout: Int) throws {
        do {
            try mgr.waitForUp(svc, timeoutSeconds: timeout)
        } catch {
            var message = Self.message(for: error)
            if let tail = try? mgr.logs(of: svc, lines: 40),
               !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                message += "\nLast 40 log lines:\n\(tail)"
            }
            throw ToolError.failed(message)
        }
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
        case ToolError.failed(let msg): return msg
        case LogFilter.QueryError.invalidPattern(let pattern):
            return "Invalid regex pattern '\(pattern)'."
        case LogFilter.QueryError.invalidDuration(let duration):
            return "Invalid duration '\(duration)' — use forms like \"30s\", \"5m\", \"2h\"."
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
