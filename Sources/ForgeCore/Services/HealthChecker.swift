import Foundation

/// Asks a service's Spring Boot Actuator whether it is actually ready, via
/// `curl http://127.0.0.1:<port>/actuator/health`. A bound port alone is not
/// readiness for Spring Cloud — it answers long before Nacos registration
/// and bean initialization finish.
public struct HealthChecker: Sendable {
    public enum Result: Sendable, Equatable {
        /// HTTP 200 with `"status":"UP"` — fully ready.
        case ready
        /// HTTP 404 — the service exposes no actuator; a bound port is the
        /// best signal available, so callers should treat this as ready.
        case noActuator
        /// Timeout, connection reset, 503/DOWN — still initializing.
        case notReady
    }

    let runner: any CommandRunning

    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    public func check(port: Int) -> Result {
        let url = "http://127.0.0.1:\(port)/actuator/health"
        guard let result = try? runner.run("/usr/bin/curl", ["-s", "-m", "1", "-w", "\n%{http_code}", url]),
              result.succeeded else {
            return .notReady
        }
        return Self.interpret(result.stdout)
    }

    /// `curl -w "\n%{http_code}"` output: the body, then the status code on
    /// the final line.
    static func interpret(_ output: String) -> Result {
        let lines = output.split(whereSeparator: \.isNewline)
        guard let code = lines.last.map({ $0.trimmingCharacters(in: .whitespaces) }) else {
            return .notReady
        }
        switch code {
        case "200":
            let body = lines.dropLast().joined(separator: "\n")
            let compact = body.filter { !$0.isWhitespace }
            return compact.contains(#""status":"UP""#) ? .ready : .notReady
        case "404":
            return .noActuator
        default:
            return .notReady
        }
    }
}
