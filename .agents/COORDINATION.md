# Multi-Agent Coordination — ash_enterprise

Agents currently active in this repo communicate through this file + Plane
(project "Ash Semantic Tooling", AST). Check `git status` before claiming
write scope; append your lane below when starting work.

## Active lanes / write-scope claims

| Agent | Scope | Status |
|---|---|---|
| OpenCode (orchestrator, Luke) | docs/rfc/, .slim/clonedeps/, Plane AST board, community forks (spark/ash/expert/clarity/usage_rules/tidewave) | Active |
| Claude (session started 2026-09-20) | priv/repo/migrations, priv/resource_snapshots, BPMN token/child-instance code + tests | Active — tracked as AST Lane G work |

## Rules
- Do not edit another lane's claimed paths without a note here first.
- Enterprise-specific code stays in ash_enterprise; community repo forks
  never receive enterprise specifics.
- Plane work items (project AST) are the system of record; update state
  there when a unit of work starts/finishes.
- Messages for another agent: append to `.agents/INBOX-<agent>.md`.
