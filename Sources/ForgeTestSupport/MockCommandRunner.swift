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

extension MockCommandRunner {
    /// Simulates a machine where the given ports are listening (port → pid)
    /// and the given tmux sessions exist. `ps` reports a fixed rss/etime.
    /// `javaHome` is what `/usr/libexec/java_home` answers (nil = no JDK found).
    public static func simulating(
        listeningPorts: [Int: Int32] = [:],
        sessions: Set<String> = [],
        javaHome: String? = nil
    ) -> MockCommandRunner {
        MockCommandRunner { call in
            switch call.executable {
            case "lsof":
                let port = Int(call.arguments[0].replacingOccurrences(of: "-ti:", with: ""))!
                guard let pid = listeningPorts[port] else { return CommandResult(exitCode: 1) }
                return CommandResult(exitCode: 0, stdout: "\(pid)\n")
            case "ps":
                return CommandResult(exitCode: 0, stdout: "129024 01:23:45\n")
            case "tmux" where call.arguments.first == "has-session":
                return CommandResult(exitCode: sessions.contains(call.arguments[2]) ? 0 : 1)
            case "/usr/libexec/java_home":
                guard let javaHome else { return CommandResult(exitCode: 1, stderr: "Unable to find any JVMs") }
                return CommandResult(exitCode: 0, stdout: javaHome + "\n")
            default:
                return CommandResult(exitCode: 0)
            }
        }
    }
}
