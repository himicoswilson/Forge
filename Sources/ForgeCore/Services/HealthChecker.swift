import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Asks a service's health endpoint whether it is actually ready, via an
/// in-process HTTP GET of `http://127.0.0.1:<port>/<path>`. A bound
/// port alone is not readiness for Spring Cloud — it answers long before Nacos
/// registration and bean initialization finish.
///
/// The default path is `/actuator/health` (Spring Boot Actuator). Services
/// that don't use Actuator can declare a custom `healthPath` in config.json;
/// a 404 on the default path now reports `.starting` rather than `.up`,
/// because a missing actuator typically means the app hasn't finished
/// initialising yet.
///
/// This used to shell out to `curl`, which cost one subprocess spawn per
/// port-bound service on every status poll; the transport is injectable so
/// tests still never open a socket.
public struct HealthChecker: Sendable {
    public enum Result: Sendable, Equatable {
        /// HTTP 200 with `"status":"UP"` — fully ready.
        case ready
        /// HTTP 404 — the service exposes no actuator; a bound port is the
        /// best signal available, so callers should treat this as starting
        /// (the endpoint may not be registered yet).
        case noActuator
        /// Timeout, connection reset, 503/DOWN — still initializing.
        case notReady
    }

    /// Default health check path for Spring Boot Actuator services.
    public static let defaultHealthPath = "/actuator/health"

    /// Default timeout in seconds — generous enough for GC pauses and
    /// slow startup, but short enough to avoid stalling the poll cycle.
    public static let defaultTimeout: TimeInterval = 3

    /// Blocking HTTP GET: status code and body, or nil on any transport
    /// failure (timeout, connection refused/reset).
    public typealias HTTPGet = @Sendable (_ url: URL, _ timeout: TimeInterval) -> (statusCode: Int, body: String)?

    let get: HTTPGet

    public init(get: @escaping HTTPGet = HealthChecker.urlSessionGet) {
        self.get = get
    }

    public func check(port: Int, path: String = defaultHealthPath, timeout: TimeInterval = defaultTimeout) -> Result {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)"),
              let response = get(url, timeout) else {
            return .notReady
        }
        return Self.interpret(statusCode: response.statusCode, body: response.body)
    }

    /// Pure response interpretation, shared by every transport.
    static func interpret(statusCode: Int, body: String) -> Result {
        switch statusCode {
        case 200:
            let compact = body.filter { !$0.isWhitespace }
            return compact.contains(#""status":"UP""#) ? .ready : .notReady
        case 404:
            return .noActuator
        default:
            return .notReady
        }
    }

    // MARK: - URLSession transport

    /// Shared session: no cache/cookies, and redirects are NOT followed —
    /// the 3xx itself is interpreted (as notReady), matching what plain
    /// `curl` reported before.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = defaultTimeout
        configuration.timeoutIntervalForResource = defaultTimeout
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    /// Blocking bridge over URLSession. `check` always runs on worker
    /// threads (status fan-out, waitForUp polling), never the main thread.
    public static let urlSessionGet: HTTPGet = { url, timeout in
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (statusCode: Int, body: String)?
        session.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                result = (http.statusCode, String(decoding: data ?? Data(), as: UTF8.self))
            }
            done.signal()
        }.resume()
        done.wait()
        return result
    }
}
