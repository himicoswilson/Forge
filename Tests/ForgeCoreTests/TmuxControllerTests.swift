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

    @Test("isPaneDead reads #{pane_dead} from list-panes")
    func isPaneDead() {
        let runner = MockCommandRunner { _ in CommandResult(exitCode: 0, stdout: "1\n") }
        #expect(TmuxController(runner: runner).isPaneDead("wr-auth"))
        #expect(runner.commandLines == ["tmux list-panes -t wr-auth -F #{pane_dead}"])
    }

    @Test("isPaneDead is false for a live pane or a missing session")
    func isPaneDeadFalse() {
        let live = MockCommandRunner { _ in CommandResult(exitCode: 0, stdout: "0\n") }
        #expect(!TmuxController(runner: live).isPaneDead("wr-auth"))
        let missing = MockCommandRunner { _ in CommandResult(exitCode: 1, stderr: "can't find session") }
        #expect(!TmuxController(runner: missing).isPaneDead("wr-auth"))
    }

    @Test("sessionCreated parses the #{session_created} epoch")
    func sessionCreated() {
        let runner = MockCommandRunner { _ in CommandResult(exitCode: 0, stdout: "1750000000\n") }
        let tmux = TmuxController(runner: runner)
        #expect(tmux.sessionCreated("wr-auth") == Date(timeIntervalSince1970: 1_750_000_000))
        #expect(runner.commandLines == ["tmux display-message -p -t wr-auth #{session_created}"])
        let missing = MockCommandRunner { _ in CommandResult(exitCode: 1) }
        #expect(TmuxController(runner: missing).sessionCreated("wr-auth") == nil)
    }

    @Test("killSession targets the right session")
    func killSession() throws {
        let runner = MockCommandRunner()
        let tmux = TmuxController(runner: runner)
        try tmux.killSession("wr-auth")
        #expect(runner.commandLines == ["tmux kill-session -t wr-auth"])
    }

}
