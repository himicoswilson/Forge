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

    // MARK: - Batched queries (one subprocess for any number of sessions)

    /// All sessions on the server: name → creation date, in one
    /// `list-sessions` call. Empty when no tmux server is running
    /// (tmux exits non-zero). Note: lookups in the returned dictionary
    /// are exact-match, unlike `has-session`'s prefix matching — exact
    /// is what Forge wants, it only ever queries names it created.
    public func listSessions() -> [String: Date] {
        guard let result = try? runner.run(
            "tmux", ["list-sessions", "-F", "#{session_name}\t#{session_created}"]
        ), result.succeeded else {
            return [:]
        }
        var sessions: [String: Date] = [:]
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            // Split on the LAST tab: the value side is always numeric,
            // so even a tab in a session name parses.
            guard let tab = line.lastIndex(of: "\t"),
                  let epoch = TimeInterval(line[line.index(after: tab)...]) else { continue }
            sessions[String(line[..<tab])] = Date(timeIntervalSince1970: epoch)
        }
        return sessions
    }

    /// First pane's dead flag per session, in one `list-panes -a` call
    /// (mirrors `isPaneDead`'s first-pane semantics). Empty when no tmux
    /// server is running.
    public func deadPanes() -> [String: Bool] {
        guard let result = try? runner.run(
            "tmux", ["list-panes", "-a", "-F", "#{session_name}\t#{pane_dead}"]
        ), result.succeeded else {
            return [:]
        }
        var dead: [String: Bool] = [:]
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            guard let tab = line.lastIndex(of: "\t") else { continue }
            let name = String(line[..<tab])
            // Panes are grouped by session; only the first one counts.
            if dead[name] == nil {
                dead[name] = line[line.index(after: tab)...] == "1"
            }
        }
        return dead
    }

    /// Mirrors all future pane output to a file (`pipe-pane -o 'cat >> …'`).
    /// `-o` keeps the call idempotent: it only opens a pipe when none exists.
    public func pipePane(session: String, toFile path: String) throws {
        let result = try runner.run("tmux", ["pipe-pane", "-t", session, "-o", "cat >> '\(path)'"])
        guard result.succeeded else {
            throw CommandError.failed(command: "tmux pipe-pane", exitCode: result.exitCode, stderr: result.stderr)
        }
    }

}
