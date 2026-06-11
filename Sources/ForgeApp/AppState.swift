import AppKit
import SwiftUI
import ForgeCore
import ForgeMCP

/// One project's point-in-time view for rendering.
struct ProjectSnapshot: Identifiable, Equatable, Sendable {
    let name: String
    let jdk: String?
    let root: URL
    let services: [ServiceStatus]

    var id: String { name }
    var upCount: Int { services.filter { $0.state == .up }.count }
}

struct ServiceKey: Hashable {
    let project: String
    let service: String
}

enum ServiceAction {
    case start, stop, restart, hotRestart
}

/// Owns the multi-project workspace, the MCP server, status polling and
/// service actions. Views stay thin on top of this.
@MainActor
final class AppState: ObservableObject {
    @Published var snapshots: [ProjectSnapshot] = []
    @Published var aggregate: AggregateState = .empty
    @Published var busy: Set<ServiceKey> = []
    @Published var statusLine = "Starting…"
    @Published var lastError: String?

    private let workspace = Workspace()
    private var mcp: ForgeMCPServer?
    private var pollTask: Task<Void, Never>?

    static let pollInterval: Duration = .seconds(2)

    init() {
        Task { await bootstrap() }
    }

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Registered projects come from ~/.forge/projects.json; $FORGE_PROJECT
    /// (if set) is added for this session without being persisted.
    private func bootstrap() async {
        for root in ProjectRegistry.load() {
            _ = try? await workspace.addProject(root: root)
        }
        if let env = ProcessInfo.processInfo.environment["FORGE_PROJECT"] {
            _ = try? await workspace.addProject(root: URL(fileURLWithPath: env))
        }
        await refresh()
        startPolling()

        let server = ForgeMCPServer(tools: ForgeTools(workspace: workspace))
        do {
            try await server.start()
            mcp = server
            statusLine = "MCP: http://127.0.0.1:\(ForgeMCPServer.defaultPort)\(ForgeMCPServer.endpoint)"
        } catch {
            statusLine = "MCP failed to start: \(error.localizedDescription)"
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                await self?.refresh()
            }
        }
    }

    // MARK: - Status

    /// Re-reads every service's status off the main thread.
    func refresh() async {
        let managers = await workspace.projects
        let snaps = await Task.detached(priority: .utility) {
            managers.map { manager in
                ProjectSnapshot(
                    name: manager.config.name,
                    jdk: manager.config.jdk,
                    root: manager.projectRoot,
                    services: manager.statusAll()
                )
            }
        }.value
        snapshots = snaps
        aggregate = AggregateState.aggregate(snaps.flatMap(\.services))
    }

    // MARK: - Actions

    func perform(_ action: ServiceAction, project: String, service: ServiceConfig) {
        let key = ServiceKey(project: project, service: service.name)
        guard !busy.contains(key) else { return }
        busy.insert(key)
        Task {
            if let manager = await workspace.project(named: project) {
                let result = await Task.detached(priority: .userInitiated) {
                    Result {
                        switch action {
                        case .start: try manager.start(service)
                        case .stop: try manager.stop(service)
                        case .restart: try manager.restart(service)
                        case .hotRestart: try manager.hotRestart(service)
                        }
                    }
                }.value
                if case .failure(let error) = result {
                    lastError = "\(service.name): \(Self.describe(error))"
                }
            }
            busy.remove(key)
            await refresh()
        }
    }

    /// Last `lines` lines of the service's tmux pane (for the log drawer).
    func logs(project: String, service: ServiceConfig, lines: Int = 200) async -> String {
        guard let manager = await workspace.project(named: project) else { return "" }
        return await Task.detached(priority: .utility) {
            (try? manager.logs(of: service, lines: lines)) ?? "(no tmux session — service is not running)"
        }.value
    }

    // MARK: - Projects

    func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project root containing .forge/config.json"
        guard panel.runModal() == .OK, let root = panel.url else { return }

        Task {
            do {
                try await workspace.addProject(root: root)
                try ProjectRegistry.save(await workspace.roots)
                await refresh()
            } catch ConfigError.notFound {
                lastError = "No .forge/config.json in \(root.lastPathComponent)"
            } catch {
                lastError = "Could not add project: \(error.localizedDescription)"
            }
        }
    }

    func removeProject(_ name: String) {
        Task {
            await workspace.removeProject(named: name)
            try? ProjectRegistry.save(await workspace.roots)
            await refresh()
        }
    }

    // MARK: - Helpers

    private static func describe(_ error: Error) -> String {
        switch error {
        case CommandError.failed(let command, let exitCode, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(command) failed (exit \(exitCode))" + (detail.isEmpty ? "" : ": \(detail)")
        case CommandError.launchFailed(let message):
            return "Failed to launch: \(message)"
        default:
            return error.localizedDescription
        }
    }
}
