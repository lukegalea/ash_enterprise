# MCP wiring sync note — `.mcp.json` ↔ `opencode.json`

Two project-scoped MCP configs live at the repo root and must not drift silently:

| server | `.mcp.json` (Claude Code & friends) | `opencode.json` (opencode) | notes |
|---|---|---|---|
| `tidewave` | `http://localhost:4000/tidewave/mcp` | same | needs the dev server running (`iex-server`); shows disconnected otherwise. PIN WARNING: pinned to tidewave 0.8.2 — 0.9.0 removed the `get_*_schema` family, see `docs/research/beam-observer-tooling.md`. |
| `ash-agent` | `http://127.0.0.1:4197` | same | read-only introspection MCP (`ash_describe`, `ash_validate`, `ash_search`, `ash_context`, `ash_forbidden`, `ash_daemon_status`, `ash_reload` + concept tools). **No auth by design** (loopback-only, POST-only). |
| `serena` | not configured (optional) | local: `uvx --from git+https://github.com/oraios/serena serena start-mcp-server --context ide-assistant` | symbolic Ash-DSL edits. Needs `uv`/`uvx` on PATH (host also has `~/.local/bin/uvx`). |

## Port note: why 4197, not 4100

`.mcp.json` originally pointed the ash-agent daemon at `:4100` ("no auth"). Reconciliation
(2026-10-09): the daemon is indeed **no-auth** (see `mix ash_agent.serve` moduledoc:
"the daemon is a dev tool with no auth — do not expose it"; verified: `GET /` → `405`,
`POST tools/list` → 15 tools, no credentials). The observed `401` was **not** the daemon —
host port 4100 is squatted by an unrelated WorkOS-emulation Docker container
(`node dist/cli.js --seed /seed/workos-emulate.config.yaml --port 4100` via docker-proxy).
Both configs therefore use **`http://127.0.0.1:4197`** (the DX-2 cross-client smoke port).

## Launching the ash-agent daemon

```sh
mix ash_agent.serve --port 4197   # compile-only boot; must NOT share the iex-server VM
```

Hand-check it is alive:

```sh
curl -s -X POST http://127.0.0.1:4197 -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | head -c 200
```

## Serena notes

- Cold MCP handshake measured at ~2.3s on the primed host (uv cache warm); the Elixir
  language server spins up lazily on the first symbolic operation (Expert fork — see
  `docs/research/serena-semantic-edits.md` for `ls_specific_settings`).
- Serena writes a `.serena/` project dir on activation. It is **not** gitignored in this
  repo yet (`.gitignore` churn pending) — expect it as untracked noise.

## Change protocol

When adding/removing/repointing a project MCP server, update **both** root configs in the
same PR (this file is the checklist). opencode reads `opencode.json` from the project root
and merges it with `~/.config/opencode/opencode.json(c)`; `.mcp.json` is the
Claude-Code-format twin. If one config gains a server the other cannot express, note the
asymmetry in the table above instead of letting it diverge unremarked.
