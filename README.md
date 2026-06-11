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

## Connect an AI agent (MCP)

Forge serves MCP over Streamable HTTP at `http://127.0.0.1:27182/mcp` while the
app is running. Point it at a project by launching with `FORGE_PROJECT` set to
a directory containing `.forge/config.json`.

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
