import Foundation

/// Orchestrates all shell operations for one project: status, lifecycle,
/// hot restart, and log capture. Pure composition over `CommandRunning`,
/// so every behaviour is unit-testable without touching the system.
public struct ServiceManager: Sendable {
    public let config: ForgeConfig
    public let projectRoot: URL
    let ports: PortChecker
    let tmux: TmuxController
    let runner: any CommandRunning

    public init(config: ForgeConfig, projectRoot: URL, runner: any CommandRunning = ProcessCommandRunner()) {
        self.config = config
        self.projectRoot = projectRoot
        self.runner = runner
        self.ports = PortChecker(runner: runner)
        self.tmux = TmuxController(runner: runner)
    }

    // MARK: - Status

    public func status(of service: ServiceConfig) -> ServiceStatus {
        let pids = ports.pids(onPort: service.port)
        if let pid = pids.first {
            let info = ports.processInfo(pid: pid)
            return ServiceStatus(service: service, state: .up, pid: pid, memoryKB: info?.memoryKB, uptime: info?.uptime)
        }
        if tmux.hasSession(config.sessionName(for: service)) {
            return ServiceStatus(service: service, state: .starting)
        }
        return ServiceStatus(service: service, state: .down)
    }

    public func statusAll() -> [ServiceStatus] {
        config.services.map(status(of:))
    }

    // MARK: - Lifecycle

    /// Launches `start-<name>.sh` in a new detached tmux session.
    public func start(_ service: ServiceConfig) throws {
        let script = projectRoot
            .appendingPathComponent(config.scripts)
            .appendingPathComponent("start-\(service.name).sh")
        try tmux.newSession(
            name: config.sessionName(for: service),
            command: "bash \"\(script.path)\"",
            workingDirectory: projectRoot
        )
    }

    /// Kills the service's tmux session. No-op if the session does not exist.
    public func stop(_ service: ServiceConfig) throws {
        let session = config.sessionName(for: service)
        guard tmux.hasSession(session) else { return }
        try tmux.killSession(session)
    }

    public func restart(_ service: ServiceConfig) throws {
        try stop(service)
        try start(service)
    }

    /// Recompiles the service's Maven module so Spring DevTools reloads it:
    /// `mvn compile -pl <module> -am -DskipTests -q`.
    public func hotRestart(_ service: ServiceConfig) throws {
        let module = config.module(for: service)
        let result = try runner.run(
            "mvn",
            ["compile", "-pl", module, "-am", "-DskipTests", "-q"],
            workingDirectory: projectRoot
        )
        guard result.succeeded else {
            throw CommandError.failed(command: "mvn compile -pl \(module)", exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    // MARK: - Logs

    public func logs(of service: ServiceConfig, lines: Int = 100) throws -> String {
        try tmux.capturePane(session: config.sessionName(for: service), lines: lines)
    }

    // MARK: - Warmup

    /// Core services every module depends on, per SPEC's `warmup` tool.
    public static let coreServiceNames = ["gateway", "auth", "tenant"]

    /// Starts gateway + auth + tenant plus the named module, skipping
    /// anything already up or starting. Returns the services it started.
    @discardableResult
    public func warmup(module: String) throws -> [ServiceConfig] {
        var targets = Self.coreServiceNames.compactMap(config.service(named:))
        if let moduleService = config.service(named: module), !targets.contains(moduleService) {
            targets.append(moduleService)
        }
        var started: [ServiceConfig] = []
        for service in targets where status(of: service).state == .down {
            try start(service)
            started.append(service)
        }
        return started
    }
}
