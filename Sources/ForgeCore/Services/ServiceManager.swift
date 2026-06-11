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

    // MARK: - JDK

    /// JAVA_HOME for the configured JDK version, via `/usr/libexec/java_home -v`.
    /// `nil` when no JDK is configured or the version is not installed.
    public func javaHome() -> String? {
        guard let jdk = config.jdk else { return nil }
        guard let result = try? runner.run("/usr/libexec/java_home", ["-v", jdk]),
              result.succeeded else {
            return nil
        }
        let home = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return home.isEmpty ? nil : home
    }

    // MARK: - Lifecycle

    /// Launches the service in a new detached tmux session. The start command
    /// is owned by Forge — no per-project scripts:
    /// `[JAVA_HOME=…] mvn spring-boot:run -pl <module> -am` at the project root.
    public func start(_ service: ServiceConfig) throws {
        var command = "mvn spring-boot:run -pl \(config.module(for: service)) -am"
        if let home = javaHome() {
            command = "JAVA_HOME=\"\(home)\" " + command
        }
        try tmux.newSession(
            name: config.sessionName(for: service),
            command: command,
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
    /// `mvn compile -pl <module> -am -DskipTests -q` (with the project's JDK).
    public func hotRestart(_ service: ServiceConfig) throws {
        let module = config.module(for: service)
        let mvnArgs = ["compile", "-pl", module, "-am", "-DskipTests", "-q"]
        let result: CommandResult
        if let home = javaHome() {
            result = try runner.run("env", ["JAVA_HOME=\(home)", "mvn"] + mvnArgs, workingDirectory: projectRoot)
        } else {
            result = try runner.run("mvn", mvnArgs, workingDirectory: projectRoot)
        }
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
