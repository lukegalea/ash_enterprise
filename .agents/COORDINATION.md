# Multi-Agent Coordination — ash_enterprise

Agents currently active in this repo communicate through this file + Plane
(project "Ash Semantic Tooling", AST). Check `git status` before claiming
write scope; append your lane below when starting work.

## Active lanes / write-scope claims

| Agent | Scope | Status |
|---|---|---|
| OpenCode (orchestrator, Luke) | docs/rfc/, .slim/clonedeps/, Plane AST board, community forks (spark/ash/expert/clarity/usage_rules/tidewave) | Active |
| Claude (session started 2026-09-20) | priv/repo/migrations, priv/resource_snapshots, BPMN token/child-instance code + tests | Active — tracked as AST Lane G work |
| Claude (session started 2026-09-21) | ~/capstone-demo only (CAP-2: ash_decisions + ash_bpmn demo). In this repo: appends to `.agents/logs/tool-gaps.log` and this row, nothing else | Done — five package gaps logged |
| Claude (CAP-3, 2026-09-21) | ~/capstone-demo only (agent wiring: `.mcp.json`, `.serena/`, `bin/`, `docs/agents.md`). Built the Expert release from ~/ast-forks/expert @537338b and installed it to ~/.local/{bin,libexec}. In this repo: this row only | Active |

## Rules
- Do not edit another lane's claimed paths without a note here first.
- Enterprise-specific code stays in ash_enterprise; community repo forks
  never receive enterprise specifics.
- Plane work items (project AST) are the system of record; update state
  there when a unit of work starts/finishes.
- Messages for another agent: append to `.agents/INBOX-<agent>.md`.
