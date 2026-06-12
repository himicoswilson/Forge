import Foundation
import ForgeCore
import ForgeTestSupport
import MCP
import Testing
@testable import ForgeMCP

@Suite("ForgeMCP")
struct ForgeMCPTests {

    /// Primary project: wr-prefixed services, like the original single-project setup.
    private func cloudA(_ runner: MockCommandRunner) -> ServiceManager {
        ServiceManager(
            config: ForgeConfig(
                name: "cloud-a", prefix: "wr",
                services: [
                    ServiceConfig(name: "gateway", port: 8080),
                    ServiceConfig(name: "auth", port: 9201),
                    ServiceConfig(name: "tenant", port: 9400),
                    ServiceConfig(name: "train", port: 9700),
                ]
            ),
            projectRoot: URL(fileURLWithPath: "/projects/cloud-a"),
            runner: runner,
            logsDirectory: URL(fileURLWithPath: "/logs")
        )
    }

    /// Second project sharing the "gateway" service name with cloud-a.
    private func cloudB(_ runner: MockCommandRunner) -> ServiceManager {
        ServiceManager(
            config: ForgeConfig(
                name: "cloud-b", prefix: "nb", jdk: "21",
                services: [
                    ServiceConfig(name: "gateway", port: 18080),
                    ServiceConfig(name: "billing", port: 19000),
                ]
            ),
            projectRoot: URL(fileURLWithPath: "/projects/cloud-b"),
            runner: runner,
            logsDirectory: URL(fileURLWithPath: "/logs")
        )
    }

    /// Full in-process MCP stack: real Server + Client over InMemoryTransport,
    /// two registered projects, shell scripted by MockCommandRunner.
    private func connect(_ runner: MockCommandRunner) async throws -> Client {
        let workspace = Workspace(runner: runner)
        await workspace.register(cloudA(runner))
        await workspace.register(cloudB(runner))
        let server = await ForgeMCPServer.makeServer(tools: ForgeTools(workspace: workspace))
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let client = Client(name: "forge-tests", version: "1.0.0")
        try await client.connect(transport: clientTransport)
        return client
    }

    private func text(_ content: [Tool.Content]) -> String {
        if case .text(let text, _, _) = content.first {
            return text
        }
        return ""
    }

    @Test("tools/list exposes all 7 Forge tools")
    func toolCatalog() async throws {
        let client = try await connect(.simulating())
        let (tools, _) = try await client.listTools()
        #expect(tools.map(\.name) == [
            "list_services", "get_service", "get_logs",
            "start_service", "stop_service", "restart_service",
            "hotrestart_service",
        ])
        #expect(tools.allSatisfy { $0.description?.isEmpty == false })
    }

    @Test("list_services snapshots every project and service")
    func listServices() async throws {
        let client = try await connect(.simulating(listeningPorts: [8080: 11, 19000: 22], sessions: ["wr-train"]))
        let (content, isError) = try await client.callTool(name: "list_services")
        #expect(isError != true)

        let payload = try JSONDecoder().decode(WorkspacePayload.self, from: Data(text(content).utf8))
        #expect(payload.projects.map(\.name) == ["cloud-a", "cloud-b"])
        #expect(payload.projects[0].services.map(\.state) == ["up", "down", "down", "starting"])
        #expect(payload.projects[1].jdk == "21")
        #expect(payload.projects[1].services.map(\.state) == ["down", "up"])
    }

    @Test("list_services reports how long a starting service has been starting")
    func listServicesStartingFor() async throws {
        let client = try await connect(.simulating(sessions: ["wr-train"]))
        let (content, _) = try await client.callTool(name: "list_services", arguments: ["project": "cloud-a"])
        let payload = try JSONDecoder().decode(WorkspacePayload.self, from: Data(text(content).utf8))
        let train = payload.projects[0].services.first { $0.name == "train" }
        #expect(train?.state == "starting")
        // Simulated sessions are 42 seconds old.
        #expect(train?.startingFor?.hasPrefix("00:4") == true)
    }

    @Test("list_services can be filtered to one project")
    func listServicesFiltered() async throws {
        let client = try await connect(.simulating())
        let (content, isError) = try await client.callTool(name: "list_services", arguments: ["project": "cloud-b"])
        #expect(isError != true)

        let payload = try JSONDecoder().decode(WorkspacePayload.self, from: Data(text(content).utf8))
        #expect(payload.projects.map(\.name) == ["cloud-b"])
    }

    @Test("get_service resolves a unique name across projects")
    func getService() async throws {
        let client = try await connect(.simulating(listeningPorts: [19000: 22]))
        let (content, isError) = try await client.callTool(name: "get_service", arguments: ["service": "billing"])
        #expect(isError != true)

        let payload = try JSONDecoder().decode(StatusPayload.self, from: Data(text(content).utf8))
        #expect(payload.project == "cloud-b")
        #expect(payload.state == "up")
        #expect(payload.uptime == "01:23:45")
    }

    @Test("duplicated service name requires the project argument")
    func ambiguousService() async throws {
        let client = try await connect(.simulating())
        let (content, isError) = try await client.callTool(name: "get_service", arguments: ["service": "gateway"])
        #expect(isError == true)
        #expect(text(content).contains("multiple projects"))
        #expect(text(content).contains("cloud-a, cloud-b"))

        let (resolved, ok) = try await client.callTool(
            name: "get_service", arguments: ["service": "gateway", "project": "cloud-b"])
        #expect(ok != true)
        let payload = try JSONDecoder().decode(StatusPayload.self, from: Data(text(resolved).utf8))
        #expect(payload.port == 18080)
    }

    @Test("unknown service name → isError listing project/service candidates")
    func unknownService() async throws {
        let client = try await connect(.simulating())
        let (content, isError) = try await client.callTool(name: "get_service", arguments: ["service": "nope"])
        #expect(isError == true)
        #expect(text(content).contains("Unknown service 'nope'"))
        #expect(text(content).contains("cloud-a/gateway"))
        #expect(text(content).contains("cloud-b/billing"))
    }

    @Test("missing required argument → isError, not a crash")
    func missingArgument() async throws {
        let client = try await connect(.simulating())
        let (content, isError) = try await client.callTool(name: "get_service")
        #expect(isError == true)
        #expect(text(content).contains("Missing required argument 'service'"))
    }

    @Test("get_logs tails the tmux pane with the requested line count")
    func getLogs() async throws {
        let runner = MockCommandRunner { call in
            call.executable == "tmux" && call.arguments.first == "capture-pane"
                ? CommandResult(exitCode: 0, stdout: "Started AuthApplication in 4.2 seconds\n")
                : CommandResult(exitCode: 0)
        }
        let client = try await connect(runner)
        let (content, isError) = try await client.callTool(name: "get_logs", arguments: ["service": "auth", "lines": 50])
        #expect(isError != true)
        #expect(text(content).contains("Started AuthApplication"))
        #expect(runner.commandLines.contains("tmux capture-pane -p -t wr-auth -S -50"))
    }

    @Test("start_service launches the built-in mvn command in tmux and waits until UP")
    func startService() async throws {
        // Stateful world: port 9700 only "binds" after new-session ran, so
        // the tool really exercises start → poll → UP.
        var started = false
        let runner = MockCommandRunner { call in
            switch call.executable {
            case "tmux" where call.arguments.first == "new-session":
                started = true
                return CommandResult(exitCode: 0)
            case "tmux" where call.arguments.first == "has-session":
                return CommandResult(exitCode: started ? 0 : 1)
            case "tmux" where call.arguments.first == "list-panes":
                return CommandResult(exitCode: 0, stdout: "0\n")
            case "lsof" where call.arguments == ["-ti:9700"]:
                return started ? CommandResult(exitCode: 0, stdout: "1234\n") : CommandResult(exitCode: 1)
            case "lsof":
                return CommandResult(exitCode: 1)
            case "ps":
                return CommandResult(exitCode: 0, stdout: "129024 00:00:03\n")
            case "/usr/bin/curl":
                return CommandResult(exitCode: 0, stdout: "{\"status\":\"UP\"}\n200")
            default:
                return CommandResult(exitCode: 0)
            }
        }
        let client = try await connect(runner)
        let (content, isError) = try await client.callTool(name: "start_service", arguments: ["services": ["train"]])
        #expect(isError != true)
        #expect(text(content).contains("cloud-a/train: started — UP on port 9700"))
        #expect(runner.calls.contains { $0.executable == "tmux" && $0.arguments == [
            "new-session", "-d", "-s", "wr-train", "-c", "/projects/cloud-a",
            "mvn install -pl wr-train -am -DskipTests"
                + " && mvn org.springframework.boot:spring-boot-maven-plugin:run -pl wr-train",
        ] })
    }

    @Test("start_service uses the project's JDK when configured")
    func startServiceWithJDK() async throws {
        let runner = MockCommandRunner.simulating(javaHome: "/jdk21")
        let client = try await connect(runner)
        let (content, isError) = try await client.callTool(
            name: "start_service", arguments: ["services": ["billing"], "wait": false])
        #expect(isError != true)
        #expect(text(content).contains("cloud-b/billing: started (not waiting)"))
        #expect(runner.commandLines.contains("/usr/libexec/java_home -v 21"))
        #expect(runner.calls.contains { $0.executable == "tmux" && $0.arguments == [
            "new-session", "-d", "-s", "nb-billing", "-c", "/projects/cloud-b",
            "env JAVA_HOME=\"/jdk21\" mvn install -pl nb-billing -am -DskipTests"
                + " && env JAVA_HOME=\"/jdk21\" mvn org.springframework.boot:spring-boot-maven-plugin:run -pl nb-billing",
        ] })
    }

    @Test("start_service skips a service that is already up, without error")
    func startServiceAlreadyUp() async throws {
        let runner = MockCommandRunner.simulating(listeningPorts: [9700: 1234])
        let client = try await connect(runner)
        let (content, isError) = try await client.callTool(name: "start_service", arguments: ["services": ["train"]])
        #expect(isError != true)
        #expect(text(content).contains("cloud-a/train: skipped — already up"))
        #expect(!runner.calls.contains { $0.executable == "tmux" && $0.arguments.first == "new-session" })
    }

    @Test("start_service skips a service that is already starting (wait: false)")
    func startServiceAlreadyStarting() async throws {
        let runner = MockCommandRunner.simulating(sessions: ["wr-train"])
        let client = try await connect(runner)
        let (content, isError) = try await client.callTool(
            name: "start_service", arguments: ["services": ["train"], "wait": false])
        #expect(isError != true)
        #expect(text(content).contains("cloud-a/train: skipped — already starting"))
        #expect(!runner.calls.contains { $0.executable == "tmux" && $0.arguments.first == "new-session" })
    }

    @Test("start_service clears a stale dead session instead of failing with duplicate session")
    func startServiceDeadSession() async throws {
        let runner = MockCommandRunner.simulating(deadSessions: ["wr-train"])
        let client = try await connect(runner)
        let (content, isError) = try await client.callTool(
            name: "start_service", arguments: ["services": ["train"], "wait": false])
        #expect(isError != true)
        #expect(text(content).contains("cloud-a/train: started"))
        #expect(runner.commandLines.contains("tmux kill-session -t wr-train"))
        #expect(runner.calls.contains { $0.executable == "tmux" && $0.arguments.first == "new-session" })
    }

    @Test("start_service mixes skips and starts without flagging the call as error")
    func startServiceMixedBatch() async throws {
        // auth is up, train is down.
        let runner = MockCommandRunner.simulating(listeningPorts: [9201: 22])
        let client = try await connect(runner)
        let (content, isError) = try await client.callTool(
            name: "start_service", arguments: ["services": ["auth", "train"], "wait": false])
        #expect(isError != true)
        #expect(text(content).contains("cloud-a/auth: skipped — already up"))
        #expect(text(content).contains("cloud-a/train: started"))
    }

    @Test("stop_service on a stopped service says so without killing anything")
    func stopStoppedService() async throws {
        let runner = MockCommandRunner.simulating()
        let client = try await connect(runner)
        let (content, isError) = try await client.callTool(name: "stop_service", arguments: ["services": ["train"]])
        #expect(isError != true)
        #expect(text(content).contains("not running"))
        #expect(!runner.commandLines.contains { $0.contains("kill-session") })
    }

    @Test("stop_service kills the tmux session of a running service")
    func stopRunningService() async throws {
        let runner = MockCommandRunner.simulating(listeningPorts: [9201: 22], sessions: ["wr-auth"])
        let client = try await connect(runner)
        let (content, isError) = try await client.callTool(name: "stop_service", arguments: ["services": ["auth"]])
        #expect(isError != true)
        #expect(text(content).contains("Stopped cloud-a/auth"))
        #expect(runner.commandLines.contains("tmux kill-session -t wr-auth"))
    }

    @Test("restart_service waits until the service is back UP")
    func restartService() async throws {
        // Port stays bound in the simulation, so waitForUp sees UP right after the restart.
        let runner = MockCommandRunner.simulating(listeningPorts: [9201: 22], sessions: ["wr-auth"])
        let client = try await connect(runner)
        let (content, isError) = try await client.callTool(name: "restart_service", arguments: ["services": ["auth"]])
        #expect(isError != true)
        #expect(text(content).contains("cloud-a/auth: restarted — UP on port 9201"))
        #expect(runner.commandLines.contains("tmux kill-session -t wr-auth"))
        #expect(runner.calls.contains { $0.executable == "tmux" && $0.arguments.first == "new-session" })
    }

    @Test("restart_service with wait: false returns as soon as the restart is issued")
    func restartServiceNoWait() async throws {
        let runner = MockCommandRunner.simulating(sessions: ["wr-train"])
        let client = try await connect(runner)
        let (content, isError) = try await client.callTool(
            name: "restart_service", arguments: ["services": ["train"], "wait": false])
        #expect(isError != true)
        #expect(text(content).contains("cloud-a/train: restarted (not waiting"))
        #expect(runner.calls.contains { $0.executable == "tmux" && $0.arguments.first == "new-session" })
    }

    @Test("restart_service timeout fails with the recent log tail attached")
    func restartServiceTimeout() async throws {
        let runner = MockCommandRunner { call in
            switch call.executable {
            case "tmux" where call.arguments.first == "capture-pane":
                return CommandResult(exitCode: 0, stdout: "Caused by: BeanCreationException: oops\n")
            case "tmux" where call.arguments.first == "list-panes":
                return CommandResult(exitCode: 0, stdout: "0\n")
            case "tmux":
                return CommandResult(exitCode: 0) // has-session, kill-session, new-session, pipe-pane
            case "lsof":
                return CommandResult(exitCode: 1) // port never binds
            default:
                return CommandResult(exitCode: 0)
            }
        }
        let client = try await connect(runner)
        let (content, isError) = try await client.callTool(
            name: "restart_service", arguments: ["services": ["auth"], "timeoutSeconds": 0])
        #expect(isError == true)
        #expect(text(content).contains("Timed out"))
        #expect(text(content).contains("Last 40 log lines"))
        #expect(text(content).contains("Caused by: BeanCreationException"))
    }

    @Test("hotrestart_service compiles and confirms the service is back UP")
    func hotRestart() async throws {
        let runner = MockCommandRunner.simulating(listeningPorts: [9700: 1234], sessions: ["wr-train"])
        let client = try await connect(runner)
        let (content, isError) = try await client.callTool(name: "hotrestart_service", arguments: ["services": ["train"]])
        #expect(isError != true)
        #expect(text(content).contains("Compiled 'wr-train'"))
        #expect(text(content).contains("UP on port 9700"))
        #expect(runner.commandLines.contains("mvn compile -pl wr-train -am -DskipTests -q"))
    }

    @Test("hotrestart_service on a stopped service says there is nothing to reload")
    func hotRestartStoppedService() async throws {
        let runner = MockCommandRunner.simulating()
        let client = try await connect(runner)
        let (content, isError) = try await client.callTool(name: "hotrestart_service", arguments: ["services": ["train"]])
        #expect(isError != true)
        #expect(text(content).contains("not running — nothing to reload"))
        #expect(runner.commandLines.contains("mvn compile -pl wr-train -am -DskipTests -q"))
    }

    @Test("hotrestart_service surfaces compilation failure as isError")
    func hotRestartFailure() async throws {
        let runner = MockCommandRunner { call in
            call.executable == "mvn"
                ? CommandResult(exitCode: 1, stderr: "COMPILATION ERROR in TrainService.java")
                : CommandResult(exitCode: 1)
        }
        let client = try await connect(runner)
        let (content, isError) = try await client.callTool(name: "hotrestart_service", arguments: ["services": ["train"]])
        #expect(isError == true)
        #expect(text(content).contains("COMPILATION ERROR"))
    }

    @Test("empty workspace explains how to register a project")
    func emptyWorkspace() async throws {
        let workspace = Workspace(runner: MockCommandRunner.simulating())
        let server = await ForgeMCPServer.makeServer(tools: ForgeTools(workspace: workspace))
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let client = Client(name: "forge-tests", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        let (content, isError) = try await client.callTool(name: "get_service", arguments: ["service": "auth"])
        #expect(isError == true)
        #expect(text(content).contains("No projects registered"))
    }

    @Test("unknown tool name is a protocol error, not a tool result")
    func unknownTool() async throws {
        let client = try await connect(.simulating())
        await #expect(throws: (any Error).self) {
            _ = try await client.callTool(name: "fly_to_the_moon")
        }
    }
}
