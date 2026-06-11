import Foundation
import ForgeTestSupport
import Testing
@testable import ForgeCore

@Suite("TmuxController")
struct TmuxControllerTests {

    @Test("hasSession reflects tmux exit code")
    func hasSession() {
        let runner = MockCommandRunner { call in
            CommandResult(exitCode: call.arguments.contains("wr-auth") ? 0 : 1)
        }
        let tmux = TmuxController(runner: runner)
        #expect(tmux.hasSession("wr-auth"))
        #expect(!tmux.hasSession("wr-train"))
        #expect(runner.commandLines == [
            "tmux has-session -t wr-auth",
            "tmux has-session -t wr-train",
        ])
    }

    @Test("newSession builds the exact detached-session command")
    func newSession() throws {
        let runner = MockCommandRunner()
        let tmux = TmuxController(runner: runner)
        try tmux.newSession(
            name: "wr-gateway",
            command: "bash \"/proj/scripts/start-gateway.sh\"",
            workingDirectory: URL(fileURLWithPath: "/proj")
        )
        #expect(runner.calls.first?.arguments == [
            "new-session", "-d", "-s", "wr-gateway", "-c", "/proj",
            "bash \"/proj/scripts/start-gateway.sh\"",
        ])
    }

    @Test("newSession failure surfaces stderr")
    func newSessionFailure() {
        let runner = MockCommandRunner { _ in
            CommandResult(exitCode: 1, stderr: "duplicate session: wr-gateway")
        }
        let tmux = TmuxController(runner: runner)
        #expect(throws: CommandError.failed(
            command: "tmux new-session", exitCode: 1, stderr: "duplicate session: wr-gateway"
        )) {
            try tmux.newSession(name: "wr-gateway", command: "x", workingDirectory: URL(fileURLWithPath: "/proj"))
        }
    }

    @Test("killSession targets the right session")
    func killSession() throws {
        let runner = MockCommandRunner()
        let tmux = TmuxController(runner: runner)
        try tmux.killSession("wr-auth")
        #expect(runner.commandLines == ["tmux kill-session -t wr-auth"])
    }

    @Test("capturePane requests N lines of history and returns stdout")
    func capturePane() throws {
        let runner = MockCommandRunner { _ in
            CommandResult(exitCode: 0, stdout: "Started AuthApplication in 4.2 seconds\n")
        }
        let tmux = TmuxController(runner: runner)
        let logs = try tmux.capturePane(session: "wr-auth", lines: 200)
        #expect(logs.contains("Started AuthApplication"))
        #expect(runner.commandLines == ["tmux capture-pane -p -t wr-auth -S -200"])
    }
}
