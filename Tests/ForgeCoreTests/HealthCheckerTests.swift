import Foundation
import ForgeTestSupport
import Testing
@testable import ForgeCore

@Suite("HealthChecker")
struct HealthCheckerTests {

    @Test("queries actuator health over localhost with a 1s budget")
    func argv() {
        let runner = MockCommandRunner { _ in
            CommandResult(exitCode: 0, stdout: "{\"status\":\"UP\"}\n200")
        }
        let result = HealthChecker(runner: runner).check(port: 9201)
        #expect(result == .ready)
        #expect(runner.calls.last?.executable == "/usr/bin/curl")
        #expect(runner.calls.last?.arguments == [
            "-s", "-m", "1", "-w", "\n%{http_code}", "http://127.0.0.1:9201/actuator/health",
        ])
    }

    @Test("200 with status UP → ready, tolerating JSON whitespace")
    func ready() {
        #expect(HealthChecker.interpret("{\"status\":\"UP\",\"groups\":[\"liveness\"]}\n200") == .ready)
        #expect(HealthChecker.interpret("{ \"status\" : \"UP\" }\n200") == .ready)
    }

    @Test("503 with status DOWN → notReady")
    func down() {
        #expect(HealthChecker.interpret("{\"status\":\"DOWN\"}\n503") == .notReady)
    }

    @Test("200 without an UP status → notReady")
    func unexpectedBody() {
        #expect(HealthChecker.interpret("{\"status\":\"OUT_OF_SERVICE\"}\n200") == .notReady)
    }

    @Test("404 → noActuator (service simply has no actuator endpoint)")
    func noActuator() {
        #expect(HealthChecker.interpret("{\"timestamp\":\"…\",\"error\":\"Not Found\"}\n404") == .noActuator)
    }

    @Test("curl failure (timeout, connection reset) → notReady")
    func curlFailure() {
        let runner = MockCommandRunner { _ in CommandResult(exitCode: 28) }
        #expect(HealthChecker(runner: runner).check(port: 9201) == .notReady)
    }

    @Test("empty output → notReady")
    func emptyOutput() {
        #expect(HealthChecker.interpret("") == .notReady)
    }
}
