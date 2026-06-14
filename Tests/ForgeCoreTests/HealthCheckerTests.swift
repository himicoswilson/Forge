import Foundation
import ForgeTestSupport
import Testing
@testable import ForgeCore

@Suite("HealthChecker")
struct HealthCheckerTests {

    @Test("queries actuator health over localhost with a 1s budget")
    func argv() {
        nonisolated(unsafe) var seen: (url: URL, timeout: TimeInterval)?
        let checker = HealthChecker { url, timeout in
            seen = (url, timeout)
            return (statusCode: 200, body: #"{"status":"UP"}"#)
        }
        #expect(checker.check(port: 9201) == .ready)
        #expect(seen?.url.absoluteString == "http://127.0.0.1:9201/actuator/health")
        #expect(seen?.timeout == 1)
    }

    @Test("200 with status UP → ready, tolerating JSON whitespace")
    func ready() {
        #expect(HealthChecker.interpret(statusCode: 200, body: #"{"status":"UP","groups":["liveness"]}"#) == .ready)
        #expect(HealthChecker.interpret(statusCode: 200, body: #"{ "status" : "UP" }"#) == .ready)
    }

    @Test("503 with status DOWN → notReady")
    func down() {
        #expect(HealthChecker.interpret(statusCode: 503, body: #"{"status":"DOWN"}"#) == .notReady)
    }

    @Test("200 without an UP status → notReady")
    func unexpectedBody() {
        #expect(HealthChecker.interpret(statusCode: 200, body: #"{"status":"OUT_OF_SERVICE"}"#) == .notReady)
    }

    @Test("404 → noActuator (service simply has no actuator endpoint)")
    func noActuator() {
        #expect(HealthChecker.interpret(statusCode: 404, body: #"{"error":"Not Found"}"#) == .noActuator)
    }

    @Test("transport failure (timeout, connection reset) → notReady")
    func transportFailure() {
        let checker = HealthChecker { _, _ in nil }
        #expect(checker.check(port: 9201) == .notReady)
    }

    @Test("empty 200 body → notReady")
    func emptyBody() {
        #expect(HealthChecker.interpret(statusCode: 200, body: "") == .notReady)
    }
}
