import Foundation
import ForgeCore
import ForgeTestSupport
import MCP
import Testing
@testable import ForgeMCP

@Suite("ForgeMCP")
struct ForgeMCPTests {

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

    /// Full in-process MCP stack: real Server + Client talking over
    /// InMemoryTransport, shell scripted by MockCommandRunner.
    private func connect(_ runner: MockCommandRunner) async throws -> Client {
        let manager = ServiceManager(config: config, projectRoot: root, runner: runner)
        let server = await ForgeMCPServer.makeServer(tools: ForgeTools(manager: manager))
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

    @Test("tools/list exposes all 8 Forge tools")
    func toolCatalog() async throws {
        let client = try await connect(.simulating())
        let (tools, _) = try await client.listTools()
        #expect(tools.map(\.name) == [
            "list_services", "get_service", "get_logs",
            "start_service", "stop_service", "restart_service",
            "hotrestart_service", "warmup",
        ])
        #expect(tools.allSatisfy { $0.description?.isEmpty == false })
    }

    @Test("list_services returns a JSON snapshot of every service")
    func listServices() async throws {
        let client = try await connect(.simulating(listeningPorts: [8080: 11, 9201: 22], sessions: ["wr-train"]))
        let (content, isError) = try await client.callTool(name: "list_services")
        #expect(isError != true)

        let payload = try JSONDecoder().decode(ServiceListPayload.self, from: Data(text(content).utf8))
        #expect(payload.services.map(\.name) == ["gateway", "auth", "tenant", "train"])
        #expect(payload.services.map(\.state) == ["up", "up", "down", "starting"])
        #expect(payload.services[0].pid == 11)
        #expect(payload.services[0].memoryKB == 129024)
    }

    @Test("get_service reports one service's status")
    func getService() async throws {
        let client = try await connect(.simulating(listeningPorts: [9201: 22]))
        let (content, isError) = try await client.callTool(name: "get_service", arguments: ["service": "auth"])
        #expect(isError != true)

        let payload = try JSONDecoder().decode(StatusPayload.self, from: Data(text(content).utf8))
        #expect(payload.name == "auth")
        #expect(payload.state == "up")
        #expect(payload.uptime == "01:23:45")
    }

    @Test("unknown service name → isError with the known names listed")
    func unknownService() async throws {
        let client = try await connect(.simulating())
        let (content, isError) = try await client.callTool(name: "get_service", arguments: ["service": "nope"])
        #expect(isError == true)
        #expect(text(content).contains("Unknown service 'nope'"))
        #expect(text(content).contains("gateway, auth, tenant, train"))
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

    @Test("start_service launches the start script in tmux")
    func startService() async throws {
        let runner = MockCommandRunner.simulating()
        let client = try await connect(runner)
        let (content, isError) = try await client.callTool(name: "start_service", arguments: ["service": "train"])
        #expect(isError != true)
        #expect(text(content).contains("Started train"))
        #expect(runner.calls.contains { $0.executable == "tmux" && $0.arguments == [
            "new-session", "-d", "-s", "wr-train", "-c", "/proj",
            "bash \"/proj/.claude/skills/cloud-run/scripts/start-train.sh\"",
        ] })
    }

    @Test("stop_service on a stopped service says so without killing anything")
    func stopStoppedService() async throws {
        let runner = MockCommandRunner.simulating()
        let client = try await connect(runner)
        let (content, isError) = try await client.callTool(name: "stop_service", arguments: ["service": "train"])
        #expect(isError != true)
        #expect(text(content).contains("not running"))
        #expect(!runner.commandLines.contains { $0.contains("kill-session") })
    }

    @Test("stop_service kills the tmux session of a running service")
    func stopRunningService() async throws {
        let runner = MockCommandRunner.simulating(listeningPorts: [9201: 22], sessions: ["wr-auth"])
        let client = try await connect(runner)
        let (content, isError) = try await client.callTool(name: "stop_service", arguments: ["service": "auth"])
        #expect(isError != true)
        #expect(text(content).contains("Stopped auth"))
        #expect(runner.commandLines.contains("tmux kill-session -t wr-auth"))
    }

    @Test("hotrestart_service runs the Maven module compile")
    func hotRestart() async throws {
        let runner = MockCommandRunner.simulating()
        let client = try await connect(runner)
        let (content, isError) = try await client.callTool(name: "hotrestart_service", arguments: ["service": "train"])
        #expect(isError != true)
        #expect(text(content).contains("wr-train"))
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
        let (content, isError) = try await client.callTool(name: "hotrestart_service", arguments: ["service": "train"])
        #expect(isError == true)
        #expect(text(content).contains("COMPILATION ERROR"))
    }

    @Test("warmup starts core services + module that are down")
    func warmup() async throws {
        let runner = MockCommandRunner.simulating(listeningPorts: [8080: 1], sessions: ["wr-auth"])
        let client = try await connect(runner)
        let (content, isError) = try await client.callTool(name: "warmup", arguments: ["module": "train"])
        #expect(isError != true)
        #expect(text(content).contains("tenant, train"))
        let launched = runner.calls
            .filter { $0.executable == "tmux" && $0.arguments.first == "new-session" }
            .map { $0.arguments[3] }
        #expect(launched == ["wr-tenant", "wr-train"])
    }

    @Test("unknown tool name is a protocol error, not a tool result")
    func unknownTool() async throws {
        let client = try await connect(.simulating())
        await #expect(throws: (any Error).self) {
            _ = try await client.callTool(name: "fly_to_the_moon")
        }
    }
}
