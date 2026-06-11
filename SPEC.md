# Forge

Local microservice manager for Spring Boot projects — native macOS GUI + MCP server.

---

## What it does

- Visualizes service status in real time (port alive, memory, uptime)
- Start / stop / restart / hot-restart any service with one click
- Streams live logs from each service's tmux pane
- Exposes an MCP server so AI agents can query status and trigger actions with precision

---

## Architecture

```
Forge.app
├── SwiftUI GUI          — menu-bar + main window
├── ServiceManager       — Swift layer; runs shell commands via Process
│     ├── port check     — lsof -ti:<port>
│     ├── tmux control   — new-session / kill-session / capture-pane
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
| `start_service` | `service` | Launch via start-*.sh in a new tmux session |
| `stop_service` | `service` | Kill the tmux session |
| `restart_service` | `service` | Kill session → relaunch (full restart) |
| `hotrestart_service` | `service` | `mvn compile -pl <module> -am -DskipTests -q` |
| `warmup` | `module` | Start gateway + auth + tenant + module deps |

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

`Forge` reads a config file at `.forge/config.json` in the project root:

```json
{
  "name": "normal-cloud",
  "prefix": "wr",
  "scripts": ".claude/skills/cloud-run/scripts",
  "services": [
    { "name": "gateway", "port": 8080 },
    { "name": "auth",    "port": 9201 },
    { "name": "tenant",  "port": 9400 },
    { "name": "system",  "port": 9600 },
    { "name": "train",   "port": 9700 },
    { "name": "file",    "port": 9300 }
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
| M2 | MCP server — all 8 tools, SSE transport, Claude Code verified |
| M3 | SwiftUI window — service cards + start/stop/hotrestart buttons |
| M4 | Log drawer — live tail per service |
| M5 | Menu bar icon — colour state, quick-access popover |
| M6 | Multi-project support via `.forge/config.json` |
