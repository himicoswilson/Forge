import Foundation
import ForgeCore

extension HealthChecker {
    /// Health stub that never opens a socket: every port answers
    /// `{"status":"UP"}` except `unhealthyPorts` (503 DOWN — still booting).
    public static func simulating(unhealthyPorts: Set<Int> = []) -> HealthChecker {
        HealthChecker(get: { url, _ in
            unhealthyPorts.contains(url.port ?? 0)
                ? (statusCode: 503, body: #"{"status":"DOWN"}"#)
                : (statusCode: 200, body: #"{"status":"UP"}"#)
        })
    }
}

extension ServiceManager {
    /// PID liveness stub for tests: always returns true so that mock PIDs
    /// (which don't correspond to real processes) pass the alive check.
    public static let testPidAlive: @Sendable (Int32) -> Bool = { _ in true }
}
