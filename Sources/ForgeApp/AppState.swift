import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications
import ForgeCore
import ForgeMCP

/// Display-only service status: only holds fields the menu actually renders.
/// Strips volatile uptime/memory so equality is stable between polls.
/// `logExists` is true when `~/.forge/logs/<prefix>-<service>.log` is on disk
/// — checked against one directory listing per refresh, not a stat per service.
struct DisplayStatus: Equatable, Sendable {
    let service: ServiceConfig
    let state: ServiceState
    let logExists: Bool

    init(_ full: ServiceStatus, logExists: Bool) {
        service = full.service
        state = full.state
        self.logExists = logExists
    }
}

/// One project's point-in-time view for rendering.
struct ProjectSnapshot: Identifiable, Equatable, Sendable {
    let name: String
    let jdk: String?
    let root: URL
    let services: [DisplayStatus]

    var id: String { name }
}

struct ServiceKey: Hashable {
    let project: String
    let service: String
}

enum ServiceAction {
    case start, stop, restart, hotRestart
}

/// Owns the multi-project workspace, the MCP server, status polling,
/// service actions, and ignored-service persistence.
@MainActor
final class AppState: ObservableObject {
    @Published var snapshots: [ProjectSnapshot] = []
    @Published var busyAction: [ServiceKey: ServiceAction] = [:]
    /// Non-nil once the MCP server is listening; nil while starting or if the port was unavailable.
    @Published var mcpPort: Int? = nil
    @Published var lastError: String?
    @Published var ignoredServices: Set<String> = []
    @Published var serviceOrder: [String: [String]] = [:]
    @Published var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)

    private let workspace = Workspace()
    private var mcp: ForgeMCPServer?
    private var pollTask: Task<Void, Never>?

    static let pollInterval: Duration = .seconds(2)

    /// Last-seen snapshots used to detect state transitions for notifications.
    private var previousSnapshots: [ProjectSnapshot] = []
    /// Services that became UP recently, waiting for the debounce window.
    private var pendingUpNotices: [(project: String, name: String, port: Int)] = []
    private var noticeDebounce: Task<Void, Never>?

    private var ignoredURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".forge/ignored.json")
    }

    private var orderURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".forge/order.json")
    }

    init() {
        Task { await bootstrap() }
    }

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Lifecycle

    private func bootstrap() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
        loadIgnored()
        loadOrder()
        for root in ProjectRegistry.load() {
            _ = try? await workspace.addProject(root: root)
        }
        if let env = ProcessInfo.processInfo.environment["FORGE_PROJECT"] {
            _ = try? await workspace.addProject(root: URL(fileURLWithPath: env))
        }
        await refresh()
        startPolling()

        let port = ProcessInfo.processInfo.environment["FORGE_MCP_PORT"]
            .flatMap(Int.init) ?? ForgeMCPServer.defaultPort
        let server = ForgeMCPServer(tools: ForgeTools(workspace: workspace))
        do {
            try await server.start(port: port)
            mcp = server
            mcpPort = port
        } catch {
            lastError = "MCP failed to start on port \(port) — is another Forge instance running?"
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

    func refresh() async {
        let managers = await workspace.projects
        let snaps = await Task.detached(priority: .utility) {
            // One system interrogation shared across all projects per tick.
            let statuses = ServiceManager.statusAll(of: managers)
            return zip(managers, statuses).map { manager, sts in
                let logNames = Set(
                    (try? FileManager.default.contentsOfDirectory(atPath: manager.logsDirectory.path)) ?? []
                )
                return ProjectSnapshot(
                    name: manager.config.name,
                    jdk: manager.config.jdk,
                    root: manager.projectRoot,
                    services: sts.map { status in
                        DisplayStatus(
                            status,
                            logExists: logNames.contains("\(manager.config.sessionName(for: status.service)).log")
                        )
                    }
                )
            }
        }.value
        detectTransitions(from: snapshots, to: snaps)
        if snaps != snapshots { snapshots = snaps }
    }

    // MARK: - Notifications

    /// Compares successive snapshots and fires notifications for meaningful
    /// state changes. The first snapshot (empty → populated) is treated as
    /// baseline — no "already UP" alerts on launch.
    private func detectTransitions(from old: [ProjectSnapshot], to new: [ProjectSnapshot]) {
        guard !old.isEmpty else { return }
        var newlyUp: [(project: String, name: String, port: Int)] = []

        for newSnap in new {
            guard let oldSnap = old.first(where: { $0.name == newSnap.name }) else { continue }
            for newSvc in newSnap.services {
                guard let oldSvc = oldSnap.services.first(where: {
                    $0.service.name == newSvc.service.name
                }) else { continue }

                guard oldSvc.state == .starting else { continue }
                let key = ServiceKey(project: newSnap.name, service: newSvc.service.name)

                switch newSvc.state {
                case .up:
                    newlyUp.append((newSnap.name, newSvc.service.name, newSvc.service.port))
                case .down:
                    // Only report unexpected crashes: skip user-triggered stop/restart.
                    let action = busyAction[key]
                    if action != .stop && action != .restart {
                        postNotification(
                            title: "\(newSvc.service.name) failed to start",
                            body: "The service process exited unexpectedly — check its logs."
                        )
                    }
                case .starting:
                    break
                }
            }
        }

        guard !newlyUp.isEmpty else { return }
        pendingUpNotices.append(contentsOf: newlyUp)
        noticeDebounce?.cancel()
        // Collect services that come UP within ~1 poll cycle into one notification.
        noticeDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2500))
            guard !Task.isCancelled else { return }
            self?.flushUpNotices()
        }
    }

    @MainActor
    private func flushUpNotices() {
        let batch = pendingUpNotices
        pendingUpNotices = []
        guard !batch.isEmpty else { return }
        let multiProject = Set(batch.map(\.project)).count > 1
        if batch.count == 1 {
            let svc = batch[0]
            let proj = multiProject ? " · \(svc.project)" : ""
            postNotification(title: "\(svc.name) is UP",
                            body: "Listening on port \(svc.port)\(proj)")
        } else {
            let labels = batch.map { multiProject ? "\($0.project)/\($0.name)" : $0.name }
            postNotification(title: "\(batch.count) services started",
                            body: labels.joined(separator: " · "))
        }
    }

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    // MARK: - Actions

    func perform(_ action: ServiceAction, project: String, service: ServiceConfig) {
        let key = ServiceKey(project: project, service: service.name)
        guard busyAction[key] == nil else { return }
        busyAction[key] = action
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
            busyAction.removeValue(forKey: key)
            await refresh()
        }
    }

    func startAll(project: String) {
        for status in orderedServices(for: project)
            where !isIgnored(project: project, service: status.service.name) && status.state == .down
        {
            perform(.start, project: project, service: status.service)
        }
    }

    func stopAll(project: String) {
        for status in orderedServices(for: project)
            where !isIgnored(project: project, service: status.service.name) && status.state != .down
        {
            perform(.stop, project: project, service: status.service)
        }
    }

    func copyMCPConfig() {
        guard let port = mcpPort else { return }
        let cmd = "claude mcp add --transport http forge http://127.0.0.1:\(port)/mcp"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
    }

    func openLogs(project: String, service: ServiceConfig) {
        Task {
            guard let manager = await workspace.project(named: project) else { return }
            let session = manager.config.sessionName(for: service)
            let logURL = manager.logsDirectory.appendingPathComponent("\(session).log")
            NSWorkspace.shared.open(logURL)
        }
    }

    // MARK: - Ignore

    func isIgnored(project: String, service: String) -> Bool {
        ignoredServices.contains("\(project)/\(service)")
    }

    func toggleIgnore(project: String, service: String) {
        let key = "\(project)/\(service)"
        if ignoredServices.contains(key) {
            ignoredServices.remove(key)
        } else {
            ignoredServices.insert(key)
        }
        saveIgnored()
    }

    private func loadIgnored() {
        guard let data = try? Data(contentsOf: ignoredURL),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        ignoredServices = Set(list)
    }

    private func saveIgnored() {
        let list = ignoredServices.sorted()
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? FileManager.default.createDirectory(
            at: ignoredURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: ignoredURL, options: .atomic)
    }

    // MARK: - Ordering

    /// All services for a project in the user's saved order; newly-discovered
    /// services that have no saved position are appended at the end.
    func orderedServices(for projectName: String) -> [DisplayStatus] {
        guard let snap = snapshots.first(where: { $0.name == projectName }) else { return [] }
        guard let order = serviceOrder[projectName], !order.isEmpty else { return snap.services }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return snap.services.sorted {
            (rank[$0.service.name] ?? Int.max) < (rank[$1.service.name] ?? Int.max)
        }
    }

    func moveService(in projectName: String, from indices: IndexSet, to offset: Int) {
        var ordered = orderedServices(for: projectName)
        ordered.move(fromOffsets: indices, toOffset: offset)
        serviceOrder[projectName] = ordered.map(\.service.name)
        saveOrder()
    }

    private func loadOrder() {
        guard let data = try? Data(contentsOf: orderURL),
              let dict = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return }
        serviceOrder = dict
    }

    private func saveOrder() {
        guard let data = try? JSONEncoder().encode(serviceOrder) else { return }
        try? FileManager.default.createDirectory(
            at: orderURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: orderURL, options: .atomic)
    }

    // MARK: - Launch at Login

    func setLaunchAtLogin(_ enable: Bool) {
        do {
            if enable { try SMAppService.mainApp.register() }
            else       { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = "Could not \(enable ? "enable" : "disable") launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Projects

    func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Maven project root — services are auto-discovered (.forge/config.json optional)"
        guard panel.runModal() == .OK, let root = panel.url else { return }

        Task {
            do {
                try await workspace.addProject(root: root)
                try ProjectRegistry.save(await workspace.roots)
                await refresh()
            } catch ConfigError.noServices {
                lastError = "No services found in \(root.lastPathComponent) — no Maven module declares a server.port and there is no .forge/config.json"
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
