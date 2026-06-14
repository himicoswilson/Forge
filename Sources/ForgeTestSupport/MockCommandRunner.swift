import Foundation
import ForgeCore

/// Records every invocation and answers from a scripted handler.
/// Tests never touch the real shell.
public final class MockCommandRunner: CommandRunning, @unchecked Sendable {
    public struct Call: Equatable, Sendable {
        public let executable: String
        public let arguments: [String]
        public let workingDirectory: URL?

        public var commandLine: String {
            ([executable] + arguments).joined(separator: " ")
        }
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var handler: (Call) -> CommandResult

    public init(handler: @escaping (Call) -> CommandResult = { _ in CommandResult(exitCode: 0) }) {
        self.handler = handler
    }

    public var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    public var commandLines: [String] {
        calls.map(\.commandLine)
    }

    public func respond(_ handler: @escaping (Call) -> CommandResult) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
    }

    public func run(_ executable: String, _ arguments: [String], workingDirectory: URL?) throws -> CommandResult {
        let call = Call(executable: executable, arguments: arguments, workingDirectory: workingDirectory)
        lock.lock()
        _calls.append(call)
        let handler = self.handler
        lock.unlock()
        return handler(call)
    }
}

// MARK: - Simulation factory

extension MockCommandRunner {
    /// Simulates a machine where the given ports are listening (port → pid)
    /// and the given tmux sessions exist. `ps` reports a fixed rss/etime.
    /// `javaHome` is what `/usr/libexec/java_home` answers (nil = no JDK found).
    /// Health checks run in-process — stub them with `HealthChecker.simulating`.
    ///
    /// The returned runner is **stateful**: `tmux new-session` adds the session
    /// name to the live set and `tmux kill-session` removes it, so subsequent
    /// `has-session` calls reflect mutations made during a test.
    ///
    /// `deadSessions` exist (has-session succeeds) but their pane is dead —
    /// the remain-on-exit leftover. Pre-seeded sessions report a creation
    /// time of 42 seconds ago; sessions created during the test report "now".
    public static func simulating(
        listeningPorts: [Int: Int32] = [:],
        sessions: Set<String> = [],
        deadSessions: Set<String> = [],
        javaHome: String? = nil
    ) -> MockCommandRunner {
        let state = SimulationState(sessions: sessions.union(deadSessions), dead: deadSessions, ports: listeningPorts)

        return MockCommandRunner { call in
            switch call.executable {

            case "lsof" where call.arguments.first == "-nP":
                // ["-nP", "-iTCP:8080,9201", "-sTCP:LISTEN", "-Fpn"]
                let ports = call.arguments[1].dropFirst("-iTCP:".count)
                    .split(separator: ",").compactMap { Int($0) }
                let bound = ports.compactMap { port in state.pid(onPort: port).map { (port: port, pid: $0) } }
                guard !bound.isEmpty else { return CommandResult(exitCode: 1) }
                // The f<fd> line mimics real -F output; parsers must skip it.
                let out = bound.map { "p\($0.pid)\nf23\nn*:\($0.port)" }.joined(separator: "\n") + "\n"
                return CommandResult(exitCode: 0, stdout: out)

            case "lsof":
                let port = Int(call.arguments[0].replacingOccurrences(of: "-ti:", with: ""))!
                guard let pid = state.pid(onPort: port) else { return CommandResult(exitCode: 1) }
                return CommandResult(exitCode: 0, stdout: "\(pid)\n")

            case "ps" where call.arguments.contains("pid=,rss=,etime="):
                // ["-o", "pid=,rss=,etime=", "-p", "11,22"]
                let pids = (call.arguments.last ?? "").split(separator: ",")
                let out = pids.map { "\($0) 129024 01:23:45" }.joined(separator: "\n") + "\n"
                return CommandResult(exitCode: 0, stdout: out)

            case "ps":
                return CommandResult(exitCode: 0, stdout: "129024 01:23:45\n")

            case "tmux" where call.arguments.first == "new-session":
                // ["new-session", "-d", "-s", <name>, "-c", <dir>, <cmd>]
                if let idx = call.arguments.firstIndex(of: "-s"), idx + 1 < call.arguments.count {
                    state.addSession(call.arguments[idx + 1])
                }
                return CommandResult(exitCode: 0)

            case "tmux" where call.arguments.first == "kill-session":
                // ["kill-session", "-t", <name>]
                if call.arguments.count >= 3 { state.removeSession(call.arguments[2]) }
                return CommandResult(exitCode: 0)

            case "tmux" where call.arguments.first == "has-session":
                // ["has-session", "-t", <name>]
                return CommandResult(exitCode: state.hasSession(call.arguments[2]) ? 0 : 1)

            case "tmux" where call.arguments.first == "list-sessions":
                // ["list-sessions", "-F", "#{session_name}\t#{session_created}"]
                let all = state.allSessions()
                guard !all.isEmpty else { return CommandResult(exitCode: 1, stderr: "no server running") }
                let out = all.map { "\($0.name)\t\(Int($0.created.timeIntervalSince1970))" }
                    .joined(separator: "\n") + "\n"
                return CommandResult(exitCode: 0, stdout: out)

            case "tmux" where call.arguments.first == "list-panes" && call.arguments.contains("-a"):
                // ["list-panes", "-a", "-F", "#{session_name}\t#{pane_dead}"]
                let all = state.allSessions()
                guard !all.isEmpty else { return CommandResult(exitCode: 1, stderr: "no server running") }
                let out = all.map { "\($0.name)\t\(state.isDead($0.name) ? "1" : "0")" }
                    .joined(separator: "\n") + "\n"
                return CommandResult(exitCode: 0, stdout: out)

            case "tmux" where call.arguments.first == "list-panes":
                // ["list-panes", "-t", <name>, "-F", "#{pane_dead}"]
                guard state.hasSession(call.arguments[2]) else {
                    return CommandResult(exitCode: 1, stderr: "can't find session")
                }
                return CommandResult(exitCode: 0, stdout: state.isDead(call.arguments[2]) ? "1\n" : "0\n")

            case "/usr/libexec/java_home":
                guard let javaHome else { return CommandResult(exitCode: 1, stderr: "Unable to find any JVMs") }
                return CommandResult(exitCode: 0, stdout: javaHome + "\n")

            default:
                return CommandResult(exitCode: 0)
            }
        }
    }
}

// MARK: - Internal mutable state for simulating()

/// Holds live session and port state for `MockCommandRunner.simulating`.
/// Thread-safe: all mutations go through NSLock.
private final class SimulationState: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: Set<String>
    private var dead: Set<String>
    private var createdAt: [String: Date]
    private var ports: [Int: Int32]

    init(sessions: Set<String>, dead: Set<String>, ports: [Int: Int32]) {
        self.sessions = sessions
        self.dead = dead
        // Pre-seeded sessions look 42 seconds old, deterministic enough
        // for startingFor assertions.
        self.createdAt = Dictionary(uniqueKeysWithValues: sessions.map { ($0, Date().addingTimeInterval(-42)) })
        self.ports = ports
    }

    func hasSession(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return sessions.contains(name)
    }
    /// Every live session with its creation date, sorted by name for
    /// deterministic batched list-sessions/list-panes output.
    func allSessions() -> [(name: String, created: Date)] {
        lock.lock(); defer { lock.unlock() }
        return sessions.sorted().map { ($0, createdAt[$0] ?? Date()) }
    }
    func isDead(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return dead.contains(name)
    }
    func addSession(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        sessions.insert(name)
        dead.remove(name)
        createdAt[name] = Date()
    }
    func removeSession(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        sessions.remove(name)
        dead.remove(name)
        createdAt[name] = nil
    }
    func pid(onPort port: Int) -> Int32? {
        lock.lock(); defer { lock.unlock() }; return ports[port]
    }
}
