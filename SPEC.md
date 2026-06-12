# Forge

Local microservice manager for Spring Boot projects — native macOS GUI + MCP server.

---

## What it does

- Visualizes service status in real time (port + actuator health, memory, uptime)
- Start / stop / restart / hot-restart any service with one click
- Streams live logs from each service's tmux pane; full history mirrored to `~/.forge/logs/<session>.log`
- Exposes an MCP server so AI agents can query status and trigger actions with precision

---

## Architecture

```
Forge.app
├── SwiftUI GUI          — menu-bar + main window
├── ServiceManager       — Swift layer; runs shell commands via Process
│     ├── port check     — lsof -ti:<port>
│     ├── health check   — curl /actuator/health (port bound ≠ ready)
│     ├── tmux control   — new-session / kill-session / pipe-pane / capture-pane
│     └── mvn compile    — hotrestart trigger
└── MCP Server           — HTTP/SSE on localhost:27182
      └── exposes tools to Claude Code via settings.json
```

---

## MCP Tools

| Tool | Arguments | Description |
|---|---|---|
| `list_services` | — | Returns status snapshot of all known services |
| `get_service` | `service: string` | Status of one service: up/down/starting, pid, port, memory |
| `get_logs` | `service, lines?` | Last N lines from the service's tmux pane |
| `start_service` | `service` | `mvn install -pl <module> -am && …spring-boot-maven-plugin:run -pl <module>` in a new tmux session |
| `stop_service` | `service` | Kill the tmux session |
| `restart_service` | `service` | Kill session → relaunch (full restart) |
| `hotrestart_service` | `service` | `mvn compile -pl <module> -am -DskipTests -q` |

---

## GUI

**Menu bar icon** — coloured dot: green (all up) / yellow (partial) / red (any down).

**Main window — service cards:**

```
● gateway   :8080   UP    126 MB   [Stop]  [Restart]  [⚡]
● auth      :9201   UP    118 MB   [Stop]  [Restart]  [⚡]
○ train     :9700   DOWN   —       [Start] [Restart]  [⚡]
```

**Log drawer** — click any card to expand live log tail (tmux capture-pane, auto-scroll).

---

## Tech Stack

| Layer | Choice | Reason |
|---|---|---|
| GUI | SwiftUI (macOS 13+) | Native, no Electron overhead |
| Shell bridge | `Foundation.Process` | Run tmux / mvn commands directly |
| MCP transport | HTTP SSE on `localhost:27182` | Claude Code connects via URL |
| MCP protocol | Hand-rolled in Swift (JSON) | No official Swift SDK; protocol is simple |
| Log streaming | Timer + `tmux capture-pane` poll | No dependency on pty |

---

## Project config (per project)

Services are **auto-discovered** from the Maven module tree: every leaf module reachable from the root `pom.xml`'s `<modules>` that declares a local `server.port` (in `bootstrap.yml`, `application.yml` or `.properties` under `src/main/resources`) becomes a service. Names strip the shared artifactId prefix (`ruoyi-auth` → `auth`), which also becomes the project's `prefix`.

`.forge/config.json` is **optional** — every field overrides a derived default. Entries in `services` override a discovered service with the same name *or port* (a port identifies a service, so a same-port entry renames it), or add one discovery can't see (e.g. port lives in Nacos):

```json
{
  "name": "normal-cloud",
  "prefix": "wr",
  "jdk": "17",
  "services": [
    { "name": "system", "port": 9600, "module": "wr-system-svc" }
  ]
}
```

Multiple projects can be registered; Forge switches between them from the menu bar.

---

## Claude Code integration

Add to `.claude/settings.json`:

```json
{
  "mcpServers": {
    "forge": {
      "type": "sse",
      "url": "http://localhost:27182/sse"
    }
  }
}
```

AI then calls `forge:get_service`, `forge:hotrestart_service`, etc. directly — no shell guessing.

---

## Milestones

| # | Deliverable |
|---|---|
| M1 | ServiceManager Swift layer — all shell ops working, unit-tested |
| M2 | MCP server — all 7 tools, SSE transport, Claude Code verified |
| M3 | SwiftUI window — service cards + start/stop/hotrestart buttons |
| M4 | Log drawer — live tail per service |
| M5 | Menu bar icon — colour state, quick-access popover |
| M6 | Multi-project support via `.forge/config.json` |
