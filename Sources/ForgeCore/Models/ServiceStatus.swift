import Foundation

public enum ServiceState: String, Sendable, Codable, Equatable {
    /// Port is listening.
    case up
    /// tmux session exists but the port is not listening yet.
    case starting
    /// No session, no listener.
    case down
}

/// Point-in-time status snapshot of one service.
public struct ServiceStatus: Sendable, Equatable {
    public let service: ServiceConfig
    public let state: ServiceState
    public let pid: Int32?
    /// Resident set size in kilobytes (from `ps -o rss=`), nil when down.
    public let memoryKB: Int?
    /// Elapsed time string from `ps -o etime=` (e.g. "01:23:45"), nil when down.
    public let uptime: String?

    public init(service: ServiceConfig, state: ServiceState, pid: Int32? = nil, memoryKB: Int? = nil, uptime: String? = nil) {
        self.service = service
        self.state = state
        self.pid = pid
        self.memoryKB = memoryKB
        self.uptime = uptime
    }
}
