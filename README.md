# Forge

Local microservice manager for Spring Boot projects — native macOS menu-bar GUI + MCP server for AI agents.

See [SPEC.md](SPEC.md) for the full design.

## Requirements

- macOS 13+, Xcode 16+ (Swift 6 toolchain)
- `tmux` and `mvn` on PATH (runtime only — not needed for tests)

## Develop

```sh
make test    # run the unit suite
make run     # launch the menu-bar app
make app     # build a double-clickable Forge.app
```

The package also opens directly in Xcode: `open Package.swift`.

## Configure a project

Drop a `.forge/config.json` into the project root — only `services` is required:

```json
{
  "services": [
    { "name": "gateway", "port": 8080 },
    { "name": "auth",    "port": 9201 }
  ]
}
```

Forge owns the start command (`mvn spring-boot:run -pl <module> -am` in a tmux
session) — no start scripts needed. Optional keys:

- `name` — project display name (default: folder name)
- `prefix` — tmux session / Maven module prefix (default: `name`); modules
  resolve to `<prefix>-<service>`, overridable per service via `module`
- `jdk` — JDK version, e.g. `"17"` (default: read from `.java-version` in the
  project root; resolved to a `JAVA_HOME` via `/usr/libexec/java_home`)

## Run it

1. `make app` and move `Forge.app` to /Applications (or just `make run` during development)
2. Launch Forge — it appears in the menu bar
3. Menu bar → **Add Project…** → pick the project root. The choice persists in
   `~/.forge/projects.json`; register as many projects as you like.
   (`FORGE_PROJECT=/path make run` also works for a one-off session.)

## Connect an AI agent (MCP)

Forge serves MCP over Streamable HTTP at `http://127.0.0.1:27182/mcp` while the
app is running — one server for all registered projects. Tools accept an
optional `project` argument, only needed when a service name exists in more
than one project.

Register with Claude Code:

```sh
claude mcp add --transport http forge http://127.0.0.1:27182/mcp
```

or in your project's `.mcp.json`:

```json
{
  "mcpServers": {
    "forge": { "type": "http", "url": "http://127.0.0.1:27182/mcp" }
  }
}
```

Tools: `list_services`, `get_service`, `get_logs`, `start_service`,
`stop_service`, `restart_service`, `hotrestart_service`, `warmup`.
