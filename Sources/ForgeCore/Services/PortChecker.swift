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

    // MARK: - Batched queries (one subprocess for any number of ports/pids)

    /// rss/etime for one process, from a batched `ps` call.
    public struct ProcessStats: Sendable, Equatable {
        public let memoryKB: Int
        public let uptime: String

        public init(memoryKB: Int, uptime: String) {
            self.memoryKB = memoryKB
            self.uptime = uptime
        }
    }

    /// PIDs in LISTEN state per port — a single
    /// `lsof -nP -iTCP:<p1>,<p2>,… -sTCP:LISTEN -Fpn` for all ports.
    /// Unlike `pids(onPort:)` this only matches listeners, never clients
    /// connected to the port. Empty when no port is bound (lsof exits
    /// non-zero on no matches) or `ports` is empty.
    public func listeningPids(onPorts ports: [Int]) -> [Int: [Int32]] {
        guard !ports.isEmpty else { return [:] }
        let portList = ports.map(String.init).joined(separator: ",")
        guard let result = try? runner.run(
            "lsof", ["-nP", "-iTCP:\(portList)", "-sTCP:LISTEN", "-Fpn"]
        ), result.succeeded else {
            return [:]
        }
        return Self.parseListeners(result.stdout)
    }

    /// Memory/uptime per PID — a single `ps -o pid=,rss=,etime= -p <p1>,<p2>,…`.
    /// Parses whatever ps printed even on a non-zero exit: ps exits 1 when
    /// ANY listed pid is already gone but still reports the live ones.
    public func processStats(of pids: [Int32]) -> [Int32: ProcessStats] {
        guard !pids.isEmpty else { return [:] }
        let pidList = pids.map(String.init).joined(separator: ",")
        guard let result = try? runner.run("ps", ["-o", "pid=,rss=,etime=", "-p", pidList]) else {
            return [:]
        }
        return Self.parseStats(result.stdout)
    }

    /// Parses `lsof -F p n` output: a `p<PID>` line opens a process set,
    /// each socket contributes an `n<addr>` line (`*:8080`, `127.0.0.1:8080`,
    /// `[::1]:8080`); other field lines (`f<fd>`, …) are skipped. The same
    /// pid appears once per address family — dedupe per port, keeping
    /// first-seen order so `pids.first` stays deterministic.
    static func parseListeners(_ stdout: String) -> [Int: [Int32]] {
        var result: [Int: [Int32]] = [:]
        var currentPid: Int32?
        for line in stdout.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("p") {
                currentPid = Int32(line.dropFirst())
            } else if line.hasPrefix("n") {
                guard let pid = currentPid,
                      let portText = line.split(separator: ":").last,
                      let port = Int(portText) else { continue }
                if result[port]?.contains(pid) != true {
                    result[port, default: []].append(pid)
                }
            }
        }
        return result
    }

    /// Parses `ps -o pid=,rss=,etime=` lines; malformed lines are skipped.
    static func parseStats(_ stdout: String) -> [Int32: ProcessStats] {
        var result: [Int32: ProcessStats] = [:]
        for line in stdout.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3, let pid = Int32(fields[0]), let rss = Int(fields[1]) else { continue }
            result[pid] = ProcessStats(memoryKB: rss, uptime: String(fields[2]))
        }
        return result
    }
}
