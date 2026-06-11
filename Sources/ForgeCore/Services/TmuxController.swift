import Foundation

/// Thin, fully testable wrapper around the tmux commands Forge needs.
public struct TmuxController: Sendable {
    let runner: any CommandRunning

    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    public func hasSession(_ name: String) -> Bool {
        guard let result = try? runner.run("tmux", ["has-session", "-t", name]) else {
            return false
        }
        return result.succeeded
    }

    /// Starts a detached session running `command` with the given working directory.
    public func newSession(name: String, command: String, workingDirectory: URL) throws {
        let result = try runner.run(
            "tmux",
            ["new-session", "-d", "-s", name, "-c", workingDirectory.path, command]
        )
        guard result.succeeded else {
            throw CommandError.failed(command: "tmux new-session", exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    public func killSession(_ name: String) throws {
        let result = try runner.run("tmux", ["kill-session", "-t", name])
        guard result.succeeded else {
            throw CommandError.failed(command: "tmux kill-session", exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    /// Last `lines` lines of the session's pane (`capture-pane -p -S -<lines>`).
    public func capturePane(session: String, lines: Int) throws -> String {
        let result = try runner.run("tmux", ["capture-pane", "-p", "-t", session, "-S", "-\(lines)"])
        guard result.succeeded else {
            throw CommandError.failed(command: "tmux capture-pane", exitCode: result.exitCode, stderr: result.stderr)
        }
        return result.stdout
    }
}
