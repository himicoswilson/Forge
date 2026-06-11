import Foundation
@testable import ForgeCore

/// Records every invocation and answers from a scripted handler.
/// Tests never touch the real shell.
final class MockCommandRunner: CommandRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
        let workingDirectory: URL?

        var commandLine: String {
            ([executable] + arguments).joined(separator: " ")
        }
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var handler: (Call) -> CommandResult

    init(handler: @escaping (Call) -> CommandResult = { _ in CommandResult(exitCode: 0) }) {
        self.handler = handler
    }

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    var commandLines: [String] {
        calls.map(\.commandLine)
    }

    func respond(_ handler: @escaping (Call) -> CommandResult) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
    }

    func run(_ executable: String, _ arguments: [String], workingDirectory: URL?) throws -> CommandResult {
        let call = Call(executable: executable, arguments: arguments, workingDirectory: workingDirectory)
        lock.lock()
        _calls.append(call)
        let handler = self.handler
        lock.unlock()
        return handler(call)
    }
}
