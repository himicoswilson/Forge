import Foundation
import ForgeTestSupport
import Testing
@testable import ForgeCore

@Suite("ServiceManager")
struct ServiceManagerTests {

    let config = ForgeConfig(
        name: "normal-cloud",
        prefix: "wr",
        services: [
            ServiceConfig(name: "gateway", port: 8080),
            ServiceConfig(name: "auth", port: 9201),
            ServiceConfig(name: "tenant", port: 9400),
            ServiceConfig(name: "train", port: 9700),
        ]
    )
    let root = URL(fileURLWithPath: "/proj")

    /// Simulates a machine where the given ports are listening and the
    /// given tmux sessions exist.
    private func world(listeningPorts: [Int: Int32] = [:], sessions: Set<String> = []) -> MockCommandRunner {
        .simulating(listeningPorts: listeningPorts, sessions: sessions)
    }

    private func manager(_ runner: MockCommandRunner, config: ForgeConfig? = nil, health: HealthChecker = .simulating()) -> ServiceManager {
        ServiceManager(
            config: config ?? self.config,
            projectRoot: root,
            runner: runner,
            logsDirectory: URL(fileURLWithPath: "/logs"),
            health: health
        )
    }

    // MARK: - Status

    @Test("port listening → up, with pid + memory + uptime")
    func statusUp() {
        let mgr = manager(world(listeningPorts: [9201: 4242]))
        let status = mgr.status(of: config.service(named: "auth")!)
        #expect(status.state == .up)
        #expect(status.pid == 4242)
        #expect(status.memoryKB == 129024)
        #expect(status.uptime == "01:23:45")
    }

    @Test("session alive but port silent → starting, with elapsed startingFor")
    func statusStarting() {
        let mgr = manager(world(sessions: ["wr-train"]))
        let status = mgr.status(of: config.service(named: "train")!)
        #expect(status.state == .starting)
        // Simulated sessions are 42 seconds old.
        #expect(status.startingFor?.hasPrefix("00:4") == true)
    }

    @Test("port bound but actuator not UP yet → starting, with pid info")
    func statusStartingWhileUnhealthy() {
        let runner = MockCommandRunner.simulating(listeningPorts: [9201: 4242])
        let status = manager(runner, health: .simulating(unhealthyPorts: [9201]))
            .status(of: config.service(named: "auth")!)
        #expect(status.state == .starting)
        #expect(status.pid == 4242)
        #expect(status.memoryKB == 129024)
        // No tmux session to date the start from → falls back to process uptime.
        #expect(status.startingFor == "01:23:45")
    }

    @Test("session whose pane died (remain-on-exit) → down, not starting")
    func statusDeadPane() {
        let mgr = manager(.simulating(deadSessions: ["wr-train"]))
        #expect(mgr.status(of: config.service(named: "train")!).state == .down)
    }

    @Test("no port, no session → down")
    func statusDown() {
        let mgr = manager(world())
        let status = mgr.status(of: config.service(named: "train")!)
        #expect(status.state == .down)
        #expect(status.pid == nil)
        #expect(status.memoryKB == nil)
    }

    @Test("statusAll covers every configured service in order")
    func statusAll() {
        let mgr = manager(world(listeningPorts: [8080: 1, 9201: 2]))
        let all = mgr.statusAll()
        #expect(all.map(\.service.name) == ["gateway", "auth", "tenant", "train"])
        #expect(all.map(\.state) == [.up, .up, .down, .down])
    }

    // MARK: - statusAll snapshot path
    // statusAll interrogates the system once per call instead of per
    // service; these mirror the single-service status assertions above so
    // the two state machines can never drift apart.

    @Test("statusAll: port listening → up, with pid + memory + uptime")
    func statusAllUp() {
        let all = manager(world(listeningPorts: [9201: 4242])).statusAll()
        let auth = all.first { $0.service.name == "auth" }!
        #expect(auth.state == .up)
        #expect(auth.pid == 4242)
        #expect(auth.memoryKB == 129024)
        #expect(auth.uptime == "01:23:45")
    }

    @Test("statusAll: session alive but port silent → starting, with elapsed startingFor")
    func statusAllStarting() {
        let all = manager(world(sessions: ["wr-train"])).statusAll()
        let train = all.first { $0.service.name == "train" }!
        #expect(train.state == .starting)
        // Simulated sessions are 42 seconds old.
        #expect(train.startingFor?.hasPrefix("00:4") == true)
    }

    @Test("statusAll: port bound but actuator not UP → starting, startingFor falls back to process uptime")
    func statusAllStartingWhileUnhealthy() {
        let runner = MockCommandRunner.simulating(listeningPorts: [9201: 4242])
        let all = manager(runner, health: .simulating(unhealthyPorts: [9201])).statusAll()
        let auth = all.first { $0.service.name == "auth" }!
        #expect(auth.state == .starting)
        #expect(auth.pid == 4242)
        #expect(auth.memoryKB == 129024)
        // No tmux session to date the start from → process uptime.
        #expect(auth.startingFor == "01:23:45")
    }

    @Test("statusAll: unhealthy port with a live session dates startingFor from the session")
    func statusAllUnhealthyWithSession() {
        let runner = MockCommandRunner.simulating(listeningPorts: [9201: 4242], sessions: ["wr-auth"])
        let auth = manager(runner, health: .simulating(unhealthyPorts: [9201]))
            .statusAll().first { $0.service.name == "auth" }!
        #expect(auth.state == .starting)
        #expect(auth.startingFor?.hasPrefix("00:4") == true)
    }

    @Test("statusAll: session whose pane died → down, not starting")
    func statusAllDeadPane() {
        let all = manager(.simulating(deadSessions: ["wr-train"])).statusAll()
        #expect(all.first { $0.service.name == "train" }!.state == .down)
    }

    @Test("statusAll spawns a fixed number of subprocesses, not per-service ones")
    func statusAllSpawnCount() {
        let runner = MockCommandRunner.simulating(listeningPorts: [8080: 1, 9201: 2], sessions: ["wr-train"])
        let all = manager(runner).statusAll()
        #expect(all.map(\.state) == [.up, .up, .down, .starting])

        // 4 services, 2 bound ports, 1 session:
        // 1 lsof + 1 ps + 1 list-sessions + 1 list-panes. Health checks run
        // in-process, so they spawn nothing.
        let byExecutable = Dictionary(grouping: runner.calls, by: \.executable)
        #expect(byExecutable["lsof"]?.count == 1)
        #expect(byExecutable["ps"]?.count == 1)
        #expect(byExecutable["tmux"]?.count == 2)
        // The per-service forms must be gone from this path entirely.
        #expect(!runner.commandLines.contains { $0.contains("-ti:") })
        #expect(!runner.commandLines.contains { $0.contains("has-session") })
    }

    @Test("statusAll with everything down and no tmux server costs exactly 2 spawns")
    func statusAllAllDownSpawnCount() {
        let runner = world()
        let all = manager(runner).statusAll()
        #expect(all.allSatisfy { $0.state == .down })
        // lsof (no matches) + list-sessions (no server); ps and
        // list-panes are skipped when there is nothing to ask about.
        #expect(runner.commandLines == [
            "lsof -nP -iTCP:8080,9201,9400,9700 -sTCP:LISTEN -Fpn",
            "tmux list-sessions -F #{session_name}\t#{session_created}",
        ])
    }

    @Test("statusAll(excluding:) only asks lsof about the remaining ports")
    func statusAllExcludingPorts() {
        let runner = world()
        _ = manager(runner).statusAll(excluding: ["gateway", "train"])
        #expect(runner.commandLines.first == "lsof -nP -iTCP:9201,9400 -sTCP:LISTEN -Fpn")
    }

    @Test("status(of:) shares the batched state machine — the per-service query forms are gone")
    func statusSingleUsesBatchedQueries() {
        let runner = world(listeningPorts: [9201: 4242])
        _ = manager(runner).status(of: config.service(named: "auth")!)
        #expect(runner.commandLines.first == "lsof -nP -iTCP:9201 -sTCP:LISTEN -Fpn")
        #expect(!runner.commandLines.contains { $0.contains("-ti:") })
        #expect(!runner.commandLines.contains { $0.contains("has-session") })
        #expect(!runner.commandLines.contains { $0.contains("display-message") })
    }

    @Test("statusAll(of:) interrogates the system once for the whole workspace, not per project")
    func statusAllCrossProject() {
        let runner = MockCommandRunner.simulating(
            listeningPorts: [8080: 1, 19000: 2], sessions: ["nb-billing"]
        )
        let projectA = manager(runner)
        let projectB = ServiceManager(
            config: ForgeConfig(
                name: "cloud-b", prefix: "nb",
                services: [ServiceConfig(name: "billing", port: 19000)]
            ),
            projectRoot: URL(fileURLWithPath: "/projB"),
            runner: runner,
            logsDirectory: URL(fileURLWithPath: "/logs"),
            health: .simulating()
        )

        let all = ServiceManager.statusAll(of: [projectA, projectB])

        #expect(all.count == 2)
        #expect(all[0].map(\.state) == [.up, .down, .down, .down])
        #expect(all[1].map(\.state) == [.up])
        // One lsof for the union of both projects' ports, one tmux pair —
        // not one capture per project.
        #expect(runner.commandLines.first == "lsof -nP -iTCP:8080,9201,9400,9700,19000 -sTCP:LISTEN -Fpn")
        let byExecutable = Dictionary(grouping: runner.calls, by: \.executable)
        #expect(byExecutable["lsof"]?.count == 1)
        #expect(byExecutable["ps"]?.count == 1)
        #expect(byExecutable["tmux"]?.count == 2)
    }

    @Test("elapsedString formats like ps etime")
    func elapsedStringFormat() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        #expect(ServiceManager.elapsedString(since: now.addingTimeInterval(-42), now: now) == "00:42")
        #expect(ServiceManager.elapsedString(since: now.addingTimeInterval(-3_700), now: now) == "01:01:40")
        #expect(ServiceManager.elapsedString(since: now.addingTimeInterval(60), now: now) == "00:00")
    }

    // MARK: - Lifecycle

    /// The `new-session` invocation among all recorded calls.
    private func newSession(in runner: MockCommandRunner) -> MockCommandRunner.Call? {
        runner.calls.first { $0.executable == "tmux" && $0.arguments.first == "new-session" }
    }

    @Test("start builds deps then runs the module via the fully qualified goal, in a detached session at project root")
    func start() throws {
        let runner = world()
        try manager(runner).start(config.service(named: "train")!)
        #expect(newSession(in: runner)?.arguments == [
            "new-session", "-d", "-s", "wr-train", "-c", "/proj",
            "mvn install -pl wr-train -am -DskipTests"
                + " && mvn org.springframework.boot:spring-boot-maven-plugin:run -pl wr-train",
        ])
    }

    @Test("start pipes the session's output to a durable log file")
    func startPipesLogs() throws {
        let runner = world()
        try manager(runner).start(config.service(named: "train")!)
        #expect(runner.calls.last?.arguments == [
            "pipe-pane", "-t", "wr-train", "-o", "cat >> '/logs/wr-train.log'",
        ])
    }

    @Test("start with a configured JDK resolves JAVA_HOME and prefixes the command")
    func startWithJDK() throws {
        let jdkConfig = ForgeConfig(name: "normal-cloud", prefix: "wr", jdk: "17", services: config.services)
        let runner = MockCommandRunner.simulating(javaHome: "/Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home")
        let mgr = manager(runner, config: jdkConfig)

        try mgr.start(jdkConfig.service(named: "train")!)

        #expect(runner.commandLines.contains("/usr/libexec/java_home -v 17"))
        let home = "/Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home"
        #expect(newSession(in: runner)?.arguments.last ==
            "env JAVA_HOME=\"\(home)\" mvn install -pl wr-train -am -DskipTests"
                + " && env JAVA_HOME=\"\(home)\" mvn org.springframework.boot:spring-boot-maven-plugin:run -pl wr-train")
    }

    @Test("start falls back to PATH's java when the JDK version is not installed")
    func startWithMissingJDK() throws {
        let jdkConfig = ForgeConfig(name: "normal-cloud", prefix: "wr", jdk: "99", services: config.services)
        let runner = MockCommandRunner.simulating(javaHome: nil)
        let mgr = manager(runner, config: jdkConfig)

        try mgr.start(jdkConfig.service(named: "train")!)

        #expect(newSession(in: runner)?.arguments.last ==
            "mvn install -pl wr-train -am -DskipTests"
                + " && mvn org.springframework.boot:spring-boot-maven-plugin:run -pl wr-train")
    }

    @Test("stop kills an existing session")
    func stop() throws {
        let runner = world(sessions: ["wr-auth"])
        try manager(runner).stop(config.service(named: "auth")!)
        #expect(runner.commandLines.contains("tmux kill-session -t wr-auth"))
    }

    @Test("stop SIGTERMs a JVM that outlived its session")
    func stopOrphanedService() throws {
        let runner = world(listeningPorts: [9201: 4242])
        try manager(runner).stop(config.service(named: "auth")!)
        #expect(!runner.commandLines.contains { $0.contains("kill-session") })
        #expect(runner.commandLines.contains("kill -15 4242"))
    }

    @Test("stop is a no-op when nothing is running")
    func stopWithoutSession() throws {
        let runner = world()
        try manager(runner).stop(config.service(named: "auth")!)
        #expect(!runner.commandLines.contains { $0.contains("kill-session") })
        #expect(!runner.calls.contains { $0.executable == "kill" })
    }

    @Test("restart = kill existing session, then fresh start")
    func restart() throws {
        let runner = world(sessions: ["wr-gateway"])
        try manager(runner).restart(config.service(named: "gateway")!)
        let tmuxOps = runner.calls.filter { $0.executable == "tmux" }.map { $0.arguments[0] }
        #expect(tmuxOps == ["has-session", "kill-session", "has-session", "new-session", "pipe-pane"])
    }

    @Test("start clears a stale dead session before launching")
    func startClearsDeadSession() throws {
        let runner = MockCommandRunner.simulating(deadSessions: ["wr-train"])
        try manager(runner).start(config.service(named: "train")!)
        let tmuxOps = runner.calls.filter { $0.executable == "tmux" }.map { $0.arguments[0] }
        #expect(tmuxOps == ["has-session", "list-panes", "kill-session", "new-session", "pipe-pane"])
    }

    // MARK: - startIfNeeded

    @Test("startIfNeeded skips an up service")
    func startIfNeededUp() throws {
        let runner = world(listeningPorts: [9201: 4242])
        #expect(try manager(runner).startIfNeeded(config.service(named: "auth")!) == .alreadyUp)
        #expect(newSession(in: runner) == nil)
    }

    @Test("startIfNeeded skips a starting service")
    func startIfNeededStarting() throws {
        let runner = world(sessions: ["wr-auth"])
        #expect(try manager(runner).startIfNeeded(config.service(named: "auth")!) == .alreadyStarting)
        #expect(newSession(in: runner) == nil)
    }

    @Test("startIfNeeded launches a down service")
    func startIfNeededDown() throws {
        let runner = world()
        #expect(try manager(runner).startIfNeeded(config.service(named: "train")!) == .started)
        #expect(newSession(in: runner) != nil)
    }

    @Test("startIfNeeded treats a dead session as down and relaunches")
    func startIfNeededDeadSession() throws {
        let runner = MockCommandRunner.simulating(deadSessions: ["wr-train"])
        #expect(try manager(runner).startIfNeeded(config.service(named: "train")!) == .started)
        #expect(runner.commandLines.contains("tmux kill-session -t wr-train"))
        #expect(newSession(in: runner) != nil)
    }

    // MARK: - Hot restart

    @Test("hotRestart compiles the resolved Maven module at project root")
    func hotRestart() throws {
        let runner = world()
        try manager(runner).hotRestart(config.service(named: "train")!)
        let call = runner.calls.last!
        #expect(call.executable == "mvn")
        #expect(call.arguments == ["compile", "-pl", "wr-train", "-am", "-DskipTests", "-q"])
        #expect(call.workingDirectory == root)
    }

    @Test("hotRestart compiles with the project's JDK when configured")
    func hotRestartWithJDK() throws {
        let jdkConfig = ForgeConfig(name: "normal-cloud", prefix: "wr", jdk: "17", services: config.services)
        let runner = MockCommandRunner.simulating(javaHome: "/jdk17")
        let mgr = ServiceManager(config: jdkConfig, projectRoot: root, runner: runner)

        try mgr.hotRestart(jdkConfig.service(named: "train")!)

        let call = runner.calls.last!
        #expect(call.executable == "env")
        #expect(call.arguments == ["JAVA_HOME=/jdk17", "mvn", "compile", "-pl", "wr-train", "-am", "-DskipTests", "-q"])
    }

    @Test("hotRestart surfaces mvn failure")
    func hotRestartFailure() {
        let runner = MockCommandRunner { _ in
            CommandResult(exitCode: 1, stderr: "COMPILATION ERROR")
        }
        #expect(throws: CommandError.self) {
            try manager(runner).hotRestart(config.service(named: "train")!)
        }
    }

    @Test("hotRestart failure with empty stderr surfaces the stdout tail (mvn -q errors land there)")
    func hotRestartFailureViaStdout() {
        let runner = MockCommandRunner { call in
            call.executable == "mvn"
                ? CommandResult(exitCode: 1, stdout: "[ERROR] TrainService.java:[10,5] cannot find symbol\n")
                : CommandResult(exitCode: 0)
        }
        #expect {
            try manager(runner).hotRestart(config.service(named: "train")!)
        } throws: { error in
            guard case CommandError.failed(_, _, let detail) = error else { return false }
            return detail.contains("cannot find symbol")
        }
    }

    // MARK: - waitForUp

    @Test("waitForUp returns immediately when service is already up")
    func waitForUpAlreadyUp() throws {
        let runner = world(listeningPorts: [9201: 4242])
        try manager(runner).waitForUp(config.service(named: "auth")!, pollInterval: 0.01)
    }

    @Test("waitForUp throws immediately when service is down (session gone, build failed)")
    func waitForUpBuildFailure() {
        let runner = world() // no session, no port
        #expect(throws: CommandError.self) {
            try manager(runner).waitForUp(config.service(named: "auth")!, pollInterval: 0.01)
        }
    }

    @Test("waitForUp times out and throws when service stays starting")
    func waitForUpTimeout() {
        let runner = world(sessions: ["wr-auth"]) // session alive but port never binds
        #expect(throws: CommandError.self) {
            try manager(runner).waitForUp(
                config.service(named: "auth")!,
                timeoutSeconds: 0,
                pollInterval: 0.01
            )
        }
    }

    @Test("waitForUp polls until port appears then returns")
    func waitForUpEventuallyUp() throws {
        var calls = 0
        let runner = MockCommandRunner { call in
            switch call.executable {
            case "lsof":
                calls += 1
                // Port only "appears" after the 3rd lsof call
                guard calls >= 3 else { return CommandResult(exitCode: 1) }
                return CommandResult(exitCode: 0, stdout: "p4242\nn*:9201\n")
            case "ps":
                return CommandResult(exitCode: 0, stdout: "4242 129024 01:23:45\n")
            case "tmux" where call.arguments.first == "list-sessions":
                // session always alive while starting
                return CommandResult(exitCode: 0, stdout: "wr-auth\t1750000000\n")
            case "tmux" where call.arguments.first == "list-panes":
                return CommandResult(exitCode: 0, stdout: "wr-auth\t0\n")
            case "/usr/bin/curl":
                return CommandResult(exitCode: 0, stdout: "{\"status\":\"UP\"}\n200")
            default:
                return CommandResult(exitCode: 0)
            }
        }
        try manager(runner).waitForUp(config.service(named: "auth")!, pollInterval: 0.01)
        #expect(calls >= 3)
    }

    // MARK: - Logs

    /// Real temp directory holding a pre-written `wr-auth.log` — the one
    /// place file I/O is exercised (still no shell, no tmux).
    private func logsDir(content: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.write(to: dir.appendingPathComponent("wr-auth.log"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test("logs throws a clear error when the log file doesn't exist")
    func logsWithoutFile() {
        #expect(throws: ServiceManager.LogError.noLogFile(path: "/logs/wr-auth.log")) {
            try manager(world()).logs(of: config.service(named: "auth")!)
        }
    }

    @Test("an invalid pattern is reported as such, not masked by a missing log file")
    func logsInvalidPatternBeatsMissingFile() {
        #expect(throws: LogFilter.QueryError.invalidPattern("[")) {
            try manager(world()).logs(of: config.service(named: "auth")!, pattern: "[")
        }
    }

    @Test("logs reads the mirrored log file without touching the shell")
    func logsFromFile() throws {
        let dir = try logsDir(content: "from the file\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = world()
        let mgr = ServiceManager(config: config, projectRoot: root, runner: runner, logsDirectory: dir)
        #expect(try mgr.logs(of: config.service(named: "auth")!) == "from the file")
        #expect(runner.calls.isEmpty)
    }

    @Test("logs with a pattern greps the log file with context")
    func logsFiltered() throws {
        let dir = try logsDir(content: """
            boot ok
            noise
            2026-06-12 15:00:00 ERROR boom
            \tat com.foo.Bar(Bar.java:10)
            more noise
            """)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mgr = ServiceManager(config: config, projectRoot: root, runner: world(), logsDirectory: dir)

        let output = try mgr.logs(of: config.service(named: "auth")!, pattern: "ERROR|Exception", context: 1)

        #expect(output.contains("ERROR boom"))
        #expect(output.contains("at com.foo.Bar"))
        #expect(output.contains("noise")) // context line before the match
        #expect(!output.contains("boot ok"))
    }

    @Test("start pre-creates the log file and leaves a marker when pipe-pane fails")
    func startPipePaneFailureMarker() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = MockCommandRunner { call in
            call.executable == "tmux" && call.arguments.first == "pipe-pane"
                ? CommandResult(exitCode: 1, stderr: "no such option")
                : CommandResult(exitCode: 0)
        }
        let mgr = ServiceManager(config: config, projectRoot: root, runner: runner, logsDirectory: dir)

        try mgr.start(config.service(named: "train")!)

        let content = try String(contentsOf: dir.appendingPathComponent("wr-train.log"), encoding: .utf8)
        #expect(content.contains("pipe-pane failed"))
    }
}
