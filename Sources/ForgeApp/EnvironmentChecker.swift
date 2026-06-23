import Foundation
import UserNotifications
import ForgeCore

struct EnvCheck: Identifiable, Sendable {
    enum Status: Sendable { case ok, warning, missing }
    let id: String
    let name: String
    let status: Status
    let detail: String
    /// One-line fix hint shown below the detail when non-nil.
    let hint: String?
}

/// Checks whether the tools Forge needs are reachable in the login-shell
/// PATH (same environment `ProcessCommandRunner` uses), plus notification
/// authorisation status.
@MainActor
final class EnvironmentChecker: ObservableObject {
    @Published var checks: [EnvCheck] = []
    @Published var isChecking = false

    func run() {
        guard !isChecking else { return }
        isChecking = true
        checks = []
        Task {
            var results = await Task.detached(priority: .utility) {
                Self.toolChecks()
            }.value
            results.append(await Self.notificationCheck())
            checks = results
            isChecking = false
        }
    }

    // MARK: - Tool checks (blocking — run off-main, so nonisolated)

    private nonisolated static func toolChecks() -> [EnvCheck] {
        let runner = ProcessCommandRunner()
        return [
            checkTmux(runner),
            checkMaven(runner),
            checkJava(runner),
            checkLsof(),
        ]
    }

    private nonisolated static func checkTmux(_ runner: ProcessCommandRunner) -> EnvCheck {
        guard let r = try? runner.run("tmux", ["-V"]), r.succeeded else {
            return EnvCheck(id: "tmux", name: "tmux", status: .missing,
                           detail: "Not found on PATH",
                           hint: "brew install tmux")
        }
        return EnvCheck(id: "tmux", name: "tmux", status: .ok,
                       detail: r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), hint: nil)
    }

    private nonisolated static func checkMaven(_ runner: ProcessCommandRunner) -> EnvCheck {
        guard let r = try? runner.run("mvn", ["--version"]), r.succeeded else {
            return EnvCheck(id: "mvn", name: "Maven (mvn)", status: .missing,
                           detail: "Not found on PATH",
                           hint: "brew install maven")
        }
        let first = r.stdout.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "available"
        return EnvCheck(id: "mvn", name: "Maven (mvn)", status: .ok,
                       detail: first.trimmingCharacters(in: .whitespaces), hint: nil)
    }

    private nonisolated static func checkJava(_ runner: ProcessCommandRunner) -> EnvCheck {
        // Confirms at least one JDK is installed; if not, services can't start.
        guard let home = try? runner.run("/usr/libexec/java_home", []), home.succeeded else {
            return EnvCheck(id: "java", name: "Java", status: .missing,
                           detail: "No JDK found via /usr/libexec/java_home",
                           hint: "brew install --cask temurin")
        }
        // java -version writes to stderr on older JVMs and stdout on newer ones.
        let ver = try? runner.run("java", ["-version"])
        let raw = [ver?.stderr, ver?.stdout]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            ?? home.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = raw.components(separatedBy: .newlines)
            .first { !$0.isEmpty } ?? raw
        return EnvCheck(id: "java", name: "Java", status: .ok, detail: firstLine, hint: nil)
    }

    private nonisolated static func checkLsof() -> EnvCheck {
        guard FileManager.default.fileExists(atPath: "/usr/sbin/lsof") else {
            return EnvCheck(id: "lsof", name: "lsof", status: .missing,
                           detail: "Not found — port detection will fail",
                           hint: "lsof is a macOS built-in; check system integrity.")
        }
        return EnvCheck(id: "lsof", name: "lsof", status: .ok, detail: "Available", hint: nil)
    }

    // MARK: - Notification permission (async)

    private static func notificationCheck() async -> EnvCheck {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return EnvCheck(id: "notifications", name: "Notifications", status: .ok,
                           detail: "Authorized", hint: nil)
        case .denied:
            return EnvCheck(id: "notifications", name: "Notifications", status: .warning,
                           detail: "Denied — service alerts are silenced",
                           hint: "System Settings → Notifications → Forge")
        default:
            return EnvCheck(id: "notifications", name: "Notifications", status: .warning,
                           detail: "Not yet authorized", hint: nil)
        }
    }
}
