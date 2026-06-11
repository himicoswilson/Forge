import Foundation
import ForgeTestSupport
import Testing
@testable import ForgeCore

@Suite("ServiceManager")
struct ServiceManagerTests {

    let config = ForgeConfig(
        name: "normal-cloud",
        prefix: "wr",
        scripts: ".claude/skills/cloud-run/scripts",
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

    private func manager(_ runner: MockCommandRunner) -> ServiceManager {
        ServiceManager(config: config, projectRoot: root, runner: runner)
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

    @Test("session alive but port silent → starting")
    func statusStarting() {
        let mgr = manager(world(sessions: ["wr-train"]))
        #expect(mgr.status(of: config.service(named: "train")!).state == .starting)
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

    // MARK: - Lifecycle

    @Test("start launches start-<name>.sh in a detached session at project root")
    func start() throws {
        let runner = world()
        try manager(runner).start(config.service(named: "train")!)
        #expect(runner.calls.last?.arguments == [
            "new-session", "-d", "-s", "wr-train", "-c", "/proj",
            "bash \"/proj/.claude/skills/cloud-run/scripts/start-train.sh\"",
        ])
    }

    @Test("stop kills an existing session")
    func stop() throws {
        let runner = world(sessions: ["wr-auth"])
        try manager(runner).stop(config.service(named: "auth")!)
        #expect(runner.commandLines.last == "tmux kill-session -t wr-auth")
    }

    @Test("stop is a no-op when no session exists")
    func stopWithoutSession() throws {
        let runner = world()
        try manager(runner).stop(config.service(named: "auth")!)
        #expect(!runner.commandLines.contains { $0.contains("kill-session") })
    }

    @Test("restart = kill existing session, then fresh start")
    func restart() throws {
        let runner = world(sessions: ["wr-gateway"])
        try manager(runner).restart(config.service(named: "gateway")!)
        let tmuxOps = runner.calls.filter { $0.executable == "tmux" }.map { $0.arguments[0] }
        #expect(tmuxOps == ["has-session", "kill-session", "new-session"])
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

    @Test("hotRestart surfaces mvn failure")
    func hotRestartFailure() {
        let runner = MockCommandRunner { _ in
            CommandResult(exitCode: 1, stderr: "COMPILATION ERROR")
        }
        #expect(throws: CommandError.self) {
            try manager(runner).hotRestart(config.service(named: "train")!)
        }
    }

    // MARK: - Logs

    @Test("logs tails the service's tmux pane, default 100 lines")
    func logs() throws {
        let runner = MockCommandRunner { _ in
            CommandResult(exitCode: 0, stdout: "log line\n")
        }
        let output = try manager(runner).logs(of: config.service(named: "auth")!)
        #expect(output == "log line\n")
        #expect(runner.commandLines == ["tmux capture-pane -p -t wr-auth -S -100"])
    }

    // MARK: - Warmup

    @Test("warmup starts only the core services and module that are down")
    func warmup() throws {
        // gateway already up, auth mid-start; tenant and train are down.
        let runner = world(listeningPorts: [8080: 1], sessions: ["wr-auth"])
        let started = try manager(runner).warmup(module: "train")
        #expect(started.map(\.name) == ["tenant", "train"])
        let launched = runner.calls
            .filter { $0.executable == "tmux" && $0.arguments.first == "new-session" }
            .map { $0.arguments[3] }
        #expect(launched == ["wr-tenant", "wr-train"])
    }
}
