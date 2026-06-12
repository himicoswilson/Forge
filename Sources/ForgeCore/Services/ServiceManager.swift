import Foundation

private final class ConcurrentBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [Int: T] = [:]
    func set(_ value: T, at i: Int) { lock.lock(); defer { lock.unlock() }; data[i] = value }
    func collect(count: Int) -> [T] { (0..<count).compactMap { data[$0] } }
}

/// Orchestrates all shell operations for one project: status, lifecycle,
/// hot restart, and log capture. Pure composition over `CommandRunning`,
/// so every behaviour is unit-testable without touching the system.
public struct ServiceManager: Sendable {
    public let config: ForgeConfig
    public let projectRoot: URL
    /// Where pipe-pane mirrors each session's full output (`<session>.log`).
    public let logsDirectory: URL
    let ports: PortChecker
    let tmux: TmuxController
    let health: HealthChecker
    let runner: any CommandRunning

    public static var defaultLogsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".forge/logs")
    }

    public init(
        config: ForgeConfig,
        projectRoot: URL,
        runner: any CommandRunning = ProcessCommandRunner(),
        logsDirectory: URL? = nil
    ) {
        self.config = config
        self.projectRoot = projectRoot
        self.runner = runner
        self.logsDirectory = logsDirectory ?? Self.defaultLogsDirectory
        self.ports = PortChecker(runner: runner)
        self.tmux = TmuxController(runner: runner)
        self.health = HealthChecker(runner: runner)
    }

    // MARK: - Status

    /// A bound port means "up" only once actuator agrees: Spring Cloud
    /// services answer on their port well before they finish initializing,
    /// so port-bound + health not UP reports `.starting` (with pid info).
    public func status(of service: ServiceConfig) -> ServiceStatus {
        let session = config.sessionName(for: service)
        let pids = ports.pids(onPort: service.port)
        if let pid = pids.first {
            let info = ports.processInfo(pid: pid)
            switch health.check(port: service.port) {
            case .ready, .noActuator:
                return ServiceStatus(service: service, state: .up, pid: pid, memoryKB: info?.memoryKB, uptime: info?.uptime)
            case .notReady:
                return ServiceStatus(
                    service: service, state: .starting, pid: pid,
                    memoryKB: info?.memoryKB, uptime: info?.uptime,
                    startingFor: startingDuration(session: session) ?? info?.uptime
                )
            }
        }
        if tmux.hasSession(session) {
            // remain-on-exit can keep the session alive after its process
            // died — that's down (start failed/exited), not starting.
            if tmux.isPaneDead(session) {
                return ServiceStatus(service: service, state: .down)
            }
            return ServiceStatus(service: service, state: .starting, startingFor: startingDuration(session: session))
        }
        return ServiceStatus(service: service, state: .down)
    }

    /// Elapsed time since the session was created, formatted like `ps` etime
    /// ("00:42" / "01:23:45"). nil when the session doesn't exist.
    private func startingDuration(session: String) -> String? {
        guard let created = tmux.sessionCreated(session) else { return nil }
        let total = max(0, Int(Date().timeIntervalSince(created)))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0
            ? String(format: "%02d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    /// Returns status for every service not in `excluding`, checked in parallel.
    /// Results are returned in config order.
    public func statusAll(excluding: Set<String> = []) -> [ServiceStatus] {
        let services = config.services.filter { !excluding.contains($0.name) }
        guard !services.isEmpty else { return [] }
        let box = ConcurrentBox<ServiceStatus>()
        DispatchQueue.concurrentPerform(iterations: services.count) { i in
            box.set(status(of: services[i]), at: i)
        }
        return box.collect(count: services.count)
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
    /// is owned by Forge — no per-project scripts — and runs in two phases:
    ///
    /// `mvn install -pl <module> -am -DskipTests && mvn org.springframework.boot:spring-boot-maven-plugin:run -pl <module>`
    ///
    /// A single `mvn spring-boot:run -pl <module> -am` cannot work on typical
    /// multi-module projects: the `spring-boot` prefix only resolves in poms
    /// that declare the plugin (the leaf modules, not the aggregator root),
    /// and a direct goal with `-am` would execute `run` on every reactor
    /// module — libraries included. So: build deps via a lifecycle phase,
    /// then run only the target module with the fully qualified goal.
    /// The `env` prefix (not `VAR=… cmd`) keeps it valid under fish,
    /// which tmux may use as the session shell.
    public func start(_ service: ServiceConfig) throws {
        let session = config.sessionName(for: service)
        // A dead pane left behind by remain-on-exit would make new-session
        // fail with "duplicate session" — clear it before launching.
        if tmux.hasSession(session), tmux.isPaneDead(session) {
            try? tmux.killSession(session)
        }
        try? FileManager.default.removeItem(
            at: logsDirectory.appendingPathComponent("\(session).log")
        )
        let module = config.module(for: service)
        let env = javaHome().map { "env JAVA_HOME=\"\($0)\" " } ?? ""
        let command = "\(env)mvn install -pl \(module) -am -DskipTests"
            + " && \(env)mvn org.springframework.boot:spring-boot-maven-plugin:run -pl \(module)"
        try tmux.newSession(
            name: session,
            command: command,
            workingDirectory: projectRoot
        )
        // Mirror the session's output to a durable log file — capture-pane
        // only holds the bounded pane history. Best effort: a missing log
        // must never block a start.
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        try? tmux.pipePane(session: session, toFile: logsDirectory.appendingPathComponent("\(session).log").path)
    }

    /// Kills the service's tmux session, then SIGTERMs whatever still holds
    /// the port. The JVM is normally a child of the session and dies with
    /// it, but a service can outlive its pane (or be started outside tmux) —
    /// SIGTERM lets Spring run its shutdown hooks either way.
    public func stop(_ service: ServiceConfig) throws {
        let session = config.sessionName(for: service)
        if tmux.hasSession(session) {
            try tmux.killSession(session)
        }
        for pid in ports.pids(onPort: service.port) {
            _ = try? runner.run("kill", ["-15", "\(pid)"])
        }
    }

    public func restart(_ service: ServiceConfig) throws {
        try stop(service)
        try start(service)
    }

    /// What an idempotent start did (or skipped) for one service.
    public enum StartOutcome: Sendable, Equatable {
        case started
        case alreadyUp
        case alreadyStarting
    }

    /// Idempotent start: launches only when the service is down. Up and
    /// starting services are left alone; a stale dead session is cleared
    /// by `start` itself.
    public func startIfNeeded(_ service: ServiceConfig) throws -> StartOutcome {
        switch status(of: service).state {
        case .up: return .alreadyUp
        case .starting: return .alreadyStarting
        case .down:
            try start(service)
            return .started
        }
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
            // mvn -q prints compile errors to stdout; fall back to its tail
            // when stderr is empty so the failure is actionable.
            let detail = result.stderr.isEmpty
                ? result.stdout
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .suffix(40)
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                : result.stderr
            throw CommandError.failed(command: "mvn compile -pl \(module)", exitCode: result.exitCode, stderr: detail)
        }
    }

    // MARK: - Wait for startup

    /// Blocks until the service reaches `.up`, its process exits without binding
    /// the port (build failure), or `timeoutSeconds` elapses.
    ///
    /// - Parameter pollInterval: How often to re-check status. Injectable so
    ///   tests can use a small value without real waits.
    public func waitForUp(
        _ service: ServiceConfig,
        timeoutSeconds: Int = 300,
        pollInterval: TimeInterval = 2
    ) throws {
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        while Date() < deadline {
            switch status(of: service).state {
            case .up:
                return
            case .down:
                throw CommandError.failed(
                    command: "mvn run \(config.module(for: service))",
                    exitCode: 1,
                    stderr: "Process exited before becoming ready — check logs."
                )
            case .starting:
                Thread.sleep(forTimeInterval: pollInterval)
            }
        }
        throw CommandError.failed(
            command: "start \(service.name)",
            exitCode: 1,
            stderr: "Timed out after \(timeoutSeconds)s waiting for the service to become UP."
        )
    }

    // MARK: - Logs

    /// Log text for a service. Prefers the durable pipe-pane log file —
    /// full history since start, no terminal-width wrapping — and falls
    /// back to the tmux pane scrollback when the file doesn't exist
    /// (service started outside Forge, or an older session).
    ///
    /// - Parameters:
    ///   - lines: Cap on returned lines, tail-biased (default 100).
    ///   - pattern: Regex; keep only matching lines, ± `context` lines each.
    ///   - since: Only entries from the last N seconds, judged by line
    ///     timestamps (untimestamped lines inherit the previous entry's).
    public func logs(
        of service: ServiceConfig,
        lines: Int = 100,
        pattern: String? = nil,
        context: Int = 0,
        since: TimeInterval? = nil
    ) throws -> String {
        let session = config.sessionName(for: service)
        let file = logsDirectory.appendingPathComponent("\(session).log")
        let raw: String
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            raw = text
        } else {
            // Filtering needs the full history; a plain tail only the last N.
            let filtering = pattern != nil || since != nil
            raw = try tmux.capturePane(session: session, lines: filtering ? nil : lines)
        }
        return try LogFilter.apply(to: raw, pattern: pattern, context: context, since: since, limit: lines)
    }
}
