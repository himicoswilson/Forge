import Foundation

/// Answers "who is listening on this port?" via `lsof -ti:<port>`.
public struct PortChecker: Sendable {
    let runner: any CommandRunning

    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    /// PIDs listening on the port. Empty when the port is free
    /// (`lsof` exits non-zero when it finds nothing).
    public func pids(onPort port: Int) -> [Int32] {
        guard let result = try? runner.run("lsof", ["-ti:\(port)"]), result.succeeded else {
            return []
        }
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Memory (RSS in KB) and elapsed time for a PID via `ps -o rss=,etime=`.
    public func processInfo(pid: Int32) -> (memoryKB: Int, uptime: String)? {
        guard let result = try? runner.run("ps", ["-o", "rss=,etime=", "-p", "\(pid)"]),
              result.succeeded else {
            return nil
        }
        let fields = result.stdout.split(separator: " ", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard fields.count >= 2, let rss = Int(fields[0]) else { return nil }
        return (memoryKB: rss, uptime: fields[1])
    }
}
