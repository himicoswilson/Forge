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
└── MCP Server           — Streamable HTTP on http://127.0.0.1:27182/mcp
      └── exposes tools to AI agents (Claude Code, etc.)
```

---

## MCP Tools

Lifecycle tools take one or more services, are **idempotent**, and **block until UP by default** (`wait: true`, `timeoutSeconds: 180`); on timeout the error carries the last 40 log lines. `project` is only required when a service name exists in several registered projects.

| Tool | Arguments | Description |
|---|---|---|
| `list_services` | `project?` | Status snapshot of every service in all registered projects: up/starting/down, pid, port, memory, uptime, `startingFor` |
| `get_service` | `service, project?` | Status of one service |
| `get_logs` | `service, project?, lines?` | Last N lines from the service's tmux pane |
| `start_service` | `services[], project?, wait?, timeoutSeconds?` | `mvn install -pl <module> -am -DskipTests && …spring-boot-maven-plugin:run -pl <module>` in a new tmux session. Skips services already up/starting (never an error), clears stale dead sessions first |
| `stop_service` | `services[], project?` | Kill the tmux session, then SIGTERM whatever still holds the port |
| `restart_service` | `services[], project?, wait?, timeoutSeconds?` | Kill session → relaunch (full restart), then wait until UP |
| `hotrestart_service` | `services[], project?, wait?, timeoutSeconds?` | `mvn compile -pl <module> -am -DskipTests -q` so Spring DevTools reloads, then confirm the service is back UP |

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
| MCP transport | Streamable HTTP (stateless) on `127.0.0.1:27182/mcp` | Current MCP spec; clients connect via URL with `"type": "http"` |
| MCP protocol | Official `modelcontextprotocol/swift-sdk` | Supersedes the original hand-rolled HTTP/SSE plan |
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

Register the running app as an HTTP MCP server:

```sh
claude mcp add --transport http forge http://127.0.0.1:27182/mcp
```

or in the project's `.mcp.json`:

```json
{
  "mcpServers": {
    "forge": { "type": "http", "url": "http://127.0.0.1:27182/mcp" }
  }
}
```

AI then calls `forge:get_service`, `forge:hotrestart_service`, etc. directly — no shell guessing.

---

## Milestones

All milestones are delivered (see CLAUDE.md for the running checklist).

| # | Deliverable | Status |
|---|---|---|
| M1 | ServiceManager Swift layer — all shell ops working, unit-tested | ✅ |
| M2 | MCP server — all 7 tools, Streamable HTTP transport, Claude Code verified | ✅ |
| M3 | SwiftUI window — service cards + start/stop/hotrestart buttons | ✅ |
| M4 | Log drawer — live tail per service | ✅ |
| M5 | Menu bar icon — colour state, quick-access popover | ✅ |
| M6 | Multi-project support — workspace + registry (`~/.forge/projects.json`) | ✅ |
