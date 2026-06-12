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

    /// Whether the session's pane process has exited. With `remain-on-exit`
    /// tmux keeps the dead pane around, so the session still "exists" while
    /// nothing is running in it. `false` when the session doesn't exist.
    public func isPaneDead(_ name: String) -> Bool {
        guard let result = try? runner.run("tmux", ["list-panes", "-t", name, "-F", "#{pane_dead}"]),
              result.succeeded else {
            return false
        }
        return result.stdout.split(whereSeparator: \.isNewline).first == "1"
    }

    /// When the session was created (`#{session_created}`, a unix epoch).
    public func sessionCreated(_ name: String) -> Date? {
        guard let result = try? runner.run("tmux", ["display-message", "-p", "-t", name, "#{session_created}"]),
              result.succeeded,
              let epoch = TimeInterval(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return Date(timeIntervalSince1970: epoch)
    }

    public func killSession(_ name: String) throws {
        let result = try runner.run("tmux", ["kill-session", "-t", name])
        guard result.succeeded else {
            throw CommandError.failed(command: "tmux kill-session", exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    /// Mirrors all future pane output to a file (`pipe-pane -o 'cat >> …'`).
    /// `-o` keeps the call idempotent: it only opens a pipe when none exists.
    public func pipePane(session: String, toFile path: String) throws {
        let result = try runner.run("tmux", ["pipe-pane", "-t", session, "-o", "cat >> '\(path)'"])
        guard result.succeeded else {
            throw CommandError.failed(command: "tmux pipe-pane", exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    /// Last `lines` lines of the session's pane; `nil` captures the entire
    /// scrollback (`-S -`). `-J` re-joins lines the terminal width wrapped,
    /// so one log entry stays one line.
    public func capturePane(session: String, lines: Int?) throws -> String {
        let from = lines.map { "-\($0)" } ?? "-"
        let result = try runner.run("tmux", ["capture-pane", "-p", "-J", "-t", session, "-S", from])
        guard result.succeeded else {
            throw CommandError.failed(command: "tmux capture-pane", exitCode: result.exitCode, stderr: result.stderr)
        }
        return result.stdout
    }
}
