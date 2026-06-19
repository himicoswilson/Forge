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
        logsDirectory: URL? = nil,
        health: HealthChecker = HealthChecker()
    ) {
        self.config = config
        self.projectRoot = projectRoot
        self.runner = runner
        self.logsDirectory = logsDirectory ?? Self.defaultLogsDirectory
        self.ports = PortChecker(runner: runner)
        self.tmux = TmuxController(runner: runner)
        self.health = health
    }

    // MARK: - Status

    /// A bound port means "up" only once actuator agrees: Spring Cloud
    /// services answer on their port well before they finish initializing,
    /// so port-bound + health not UP reports `.starting` (with pid info).
    ///
    /// One state machine for every caller: this captures a one-port system
    /// snapshot and reads it, so the single-service and `statusAll` paths
    /// can never drift apart (they used to be two hand-kept copies).
    public func status(of service: ServiceConfig) -> ServiceStatus {
        status(of: service, in: captureSnapshot(forPorts: [service.port]))
    }

    /// `ps` etime formatting shared by the single-service and snapshot
    /// status paths so they can never drift apart.
    static func elapsedString(since created: Date, now: Date = Date()) -> String {
        let total = max(0, Int(now.timeIntervalSince(created)))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0
            ? String(format: "%02d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    /// Point-in-time system view captured in a fixed number of subprocess
    /// calls (≤4), independent of service count — the per-tick polling cost
    /// used to grow by 2–6 spawns per service.
    struct SystemSnapshot: Sendable {
        struct Session: Sendable {
            let created: Date
            let paneDead: Bool
        }
        /// LISTEN pids per port.
        let listeners: [Int: [Int32]]
        /// rss/etime per bound pid.
        let stats: [Int32: PortChecker.ProcessStats]
        /// tmux session name → info.
        let sessions: [String: Session]
    }

    /// One lsof + one ps + one list-sessions + one list-panes (each skipped
    /// when it has nothing to ask about).
    func captureSnapshot(forPorts portList: [Int]) -> SystemSnapshot {
        let listeners = ports.listeningPids(onPorts: portList)
        var boundPids: [Int32] = []
        var seen: Set<Int32> = []
        for pids in listeners.values {
            for pid in pids where seen.insert(pid).inserted { boundPids.append(pid) }
        }
        let stats = ports.processStats(of: boundPids)
        let created = tmux.listSessions()
        let dead = created.isEmpty ? [:] : tmux.deadPanes()
        let sessions = Dictionary(uniqueKeysWithValues: created.map { name, date in
            (name, SystemSnapshot.Session(created: date, paneDead: dead[name] ?? false))
        })
        return SystemSnapshot(listeners: listeners, stats: stats, sessions: sessions)
    }

    /// Same state machine as `status(of:)`, reading the pre-captured
    /// snapshot instead of spawning lsof/ps/tmux per service. The health
    /// curl still runs here — it is per-port by nature.
    func status(of service: ServiceConfig, in snapshot: SystemSnapshot) -> ServiceStatus {
        let session = config.sessionName(for: service)
        if let pid = snapshot.listeners[service.port]?.first {
            let info = snapshot.stats[pid]
            switch health.check(port: service.port) {
            case .ready, .noActuator:
                return ServiceStatus(service: service, state: .up, pid: pid, memoryKB: info?.memoryKB, uptime: info?.uptime)
            case .notReady:
                return ServiceStatus(
                    service: service, state: .starting, pid: pid,
                    memoryKB: info?.memoryKB, uptime: info?.uptime,
                    startingFor: snapshot.sessions[session].map { Self.elapsedString(since: $0.created) } ?? info?.uptime
                )
            }
        }
        if let sess = snapshot.sessions[session] {
            if sess.paneDead {
                return ServiceStatus(service: service, state: .down)
            }
            return ServiceStatus(service: service, state: .starting, startingFor: Self.elapsedString(since: sess.created))
        }
        return ServiceStatus(service: service, state: .down)
    }

    /// Returns status for every service not in `excluding`, checked in parallel.
    /// Results are returned in config order. The system is interrogated once
    /// up front (see `SystemSnapshot`); only health checks fan out.
    public func statusAll(excluding: Set<String> = []) -> [ServiceStatus] {
        Self.statusAll(of: [self], excluding: [config.name: excluding])[0]
    }

    /// Status for every service of every manager, in config order per manager,
    /// sharing ONE system interrogation across all projects: the per-manager
    /// path repeats the (server-global) tmux queries once per project and runs
    /// a separate lsof/ps per project, all answering about the same system.
    /// The capture goes through the first manager's runner — every manager in
    /// a workspace shares it.
    public static func statusAll(
        of managers: [ServiceManager],
        excluding: [String: Set<String>] = [:]
    ) -> [[ServiceStatus]] {
        let perManager: [[ServiceConfig]] = managers.map { manager in
            let excluded = excluding[manager.config.name] ?? []
            return manager.config.services.filter { !excluded.contains($0.name) }
        }
        var seenPorts: Set<Int> = []
        let allPorts = perManager.flatMap { $0.map(\.port) }.filter { seenPorts.insert($0).inserted }
        guard let first = managers.first, !allPorts.isEmpty else {
            return perManager.map { _ in [] }
        }
        let snapshot = first.captureSnapshot(forPorts: allPorts)
        // Only the per-port health checks fan out.
        let pairs: [(manager: Int, service: ServiceConfig)] = perManager.enumerated()
            .flatMap { i, services in services.map { (i, $0) } }
        let box = ConcurrentBox<ServiceStatus>()
        DispatchQueue.concurrentPerform(iterations: pairs.count) { i in
            box.set(managers[pairs[i].manager].status(of: pairs[i].service, in: snapshot), at: i)
        }
        let flat = box.collect(count: pairs.count)
        var result: [[ServiceStatus]] = []
        var cursor = 0
        for services in perManager {
            result.append(Array(flat[cursor ..< cursor + services.count]))
            cursor += services.count
        }
        return result
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
        let logFile = logsDirectory.appendingPathComponent("\(session).log")
        try? FileManager.default.removeItem(at: logFile)
        let module = config.module(for: service)
        let env = javaHome().map { "env JAVA_HOME=\"\($0)\" " } ?? ""
        let command = "\(env)mvn install -pl \(module) -am -DskipTests"
            + " && \(env)mvn org.springframework.boot:spring-boot-maven-plugin:run -pl \(module)"
        try tmux.newSession(
            name: session,
            command: command,
            workingDirectory: projectRoot
        )
        // The mirrored file is the only log source (there is no pane
        // fallback), so make sure it exists from the first instant, and
        // leave a visible marker if mirroring can't be attached — never
        // block the start over logging.
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        do {
            try tmux.pipePane(session: session, toFile: logFile.path)
        } catch {
            try? Data("(forge: tmux pipe-pane failed — session output is not being mirrored: \(error))\n".utf8)
                .write(to: logFile)
        }
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
        // Use listeningPids (LISTEN-only) so we only SIGTERM the process that
        // owns the server socket. pids(onPort:) returns ALL PIDs with that port
        // open — including Forge's own URLSession health-check connections —
        // which would send SIGTERM to the Forge process itself and crash the app.
        for pid in ports.listeningPids(onPorts: [service.port])[service.port] ?? [] {
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

    public enum LogError: Error, Equatable {
        /// The session's mirrored log file doesn't exist — the service
        /// wasn't started by Forge (which attaches pipe-pane on start).
        case noLogFile(path: String)
    }

    /// Log text for a service, read from the durable pipe-pane mirror —
    /// full history since start, no terminal-width wrapping. There is no
    /// other source: a service started outside Forge has no log here.
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
        // Validate query arguments first: a bad pattern should be reported
        // as such, not masked by a missing log file.
        let regex = try pattern.map(LogFilter.compile)
        let file = logsDirectory.appendingPathComponent("\(config.sessionName(for: service)).log")
        // Memory-map the log: these files grow to tens of MB, and mapping
        // hands the pages to the UTF-8 decode without first copying the whole
        // file into the heap. Same bytes decoded — purely a peak-memory win.
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            throw LogError.noLogFile(path: file.path)
        }
        // Lossy UTF-8 decode: a stray non-UTF-8 byte (GBK output, binary
        // noise) must not take down the whole log.
        let raw = String(decoding: data, as: UTF8.self)
        return try LogFilter.apply(to: raw, regex: regex, context: context, since: since, limit: lines)
    }
}
