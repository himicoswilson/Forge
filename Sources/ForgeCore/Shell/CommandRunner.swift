import Foundation

/// Result of a finished shell command.
public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }
}

/// Abstraction over running external commands. Production code uses
/// `ProcessCommandRunner`; tests inject a mock so no real shell is touched.
public protocol CommandRunning: Sendable {
    @discardableResult
    func run(_ executable: String, _ arguments: [String], workingDirectory: URL?) throws -> CommandResult
}

extension CommandRunning {
    @discardableResult
    public func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        try run(executable, arguments, workingDirectory: nil)
    }
}

public enum CommandError: Error, Equatable {
    case launchFailed(String)
    case failed(command: String, exitCode: Int32, stderr: String)
}

/// Runs commands via `Foundation.Process`, resolving executables through
/// `/usr/bin/env` so PATH lookup matches the user's shell environment.
public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    @discardableResult
    public func run(_ executable: String, _ arguments: [String], workingDirectory: URL?) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw CommandError.launchFailed("\(executable): \(error.localizedDescription)")
        }

        // Drain pipes before waiting to avoid deadlock on large output.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
