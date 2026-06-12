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

/// Environment for spawned tools. GUI apps launched from Finder inherit
/// launchd's minimal PATH (`/usr/bin:/bin:…`) — without Homebrew, jenv, etc.
/// — so we resolve the user's login-shell PATH once and reuse it.
public enum LoginEnvironment {
    /// Resolved lazily on first shell call (off the main thread).
    public static let value: [String: String] = resolve()

    static func resolve() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let resolved = shellPath(shell: env["SHELL"] ?? "/bin/zsh")
        env["PATH"] = mergedPath(
            resolved: resolved,
            current: env["PATH"],
            extras: defaultExtras(home: FileManager.default.homeDirectoryForCurrentUser.path)
                .filter { FileManager.default.fileExists(atPath: $0) }
        )
        return env
    }

    /// PATH as the user's login shell sees it (`$SHELL -l -c env`).
    private static func shellPath(shell: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "/usr/bin/env"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return nil
        }
        return parsePath(fromEnvOutput: output)
    }

    /// Extracts `PATH=` from `env` output. Pure — unit-tested.
    static func parsePath(fromEnvOutput output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("PATH=") {
            let value = String(line.dropFirst("PATH=".count))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Login PATH (or the current one), with any missing extras appended.
    /// Pure — unit-tested.
    static func mergedPath(resolved: String?, current: String?, extras: [String]) -> String {
        var path = resolved ?? current ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var seen = Set(path.split(separator: ":").map(String.init))
        for extra in extras where !seen.contains(extra) {
            path += ":" + extra
            seen.insert(extra)
        }
        return path
    }

    /// Tool locations that interactive-only shell configs (e.g. jenv in
    /// .zshrc) may hide from a login shell.
    static func defaultExtras(home: String) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.jenv/shims"]
    }
}

/// Runs commands via `Foundation.Process`, resolving executables through
/// `/usr/bin/env` so PATH lookup matches the user's shell environment.
public struct ProcessCommandRunner: CommandRunning {
    private let environment: [String: String]?

    /// - Parameter environment: variables for spawned processes.
    ///   `nil` (default) = the user's login-shell environment.
    public init(environment: [String: String]? = nil) {
        self.environment = environment
    }

    @discardableResult
    public func run(_ executable: String, _ arguments: [String], workingDirectory: URL?) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.environment = environment ?? LoginEnvironment.value
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
