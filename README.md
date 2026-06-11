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
