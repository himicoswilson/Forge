import Foundation

/// Rolled-up state across services, driving the menu-bar dot colour:
/// green (all up) / yellow (mixed or booting) / red (all down).
public enum AggregateState: String, Sendable, Equatable {
    case empty
    case allUp
    case partial
    case allDown

    public static func aggregate(_ statuses: [ServiceStatus]) -> AggregateState {
        guard !statuses.isEmpty else { return .empty }
        if statuses.allSatisfy({ $0.state == .up }) { return .allUp }
        if statuses.allSatisfy({ $0.state == .down }) { return .allDown }
        return .partial
    }
}

extension ServiceStatus {
    /// Human-readable RSS, e.g. "126 MB". `nil` while the service is down.
    public var memoryDescription: String? {
        memoryKB.map { $0 >= 1024 ? "\($0 / 1024) MB" : "\($0) KB" }
    }
}
