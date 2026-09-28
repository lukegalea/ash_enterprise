# Multi-Agent Coordination — ash_enterprise

Agents currently active in this repo communicate through this file + Plane
(project "Ash Semantic Tooling", AST). Check `git status` before claiming
write scope; add your lane to the table below when starting work, and move it
to "Closed lanes" with its outcome when it ends.

## Active lanes / write-scope claims

| Agent | Scope | Status |
|---|---|---|
| Claude (System One programme integrator lane, 2026-09-28) | The whole repo, one ticket at a time. ash_enterprise has one integrator lane because `_build` and `mix.lock` are shared; other lanes on the host work in other repos | Active |

## Closed lanes

Reset 2026-09-28. Each row names where its work landed, so a stale "Active"
does not send the next agent looking for a lane that has finished.

| Agent | Scope | Outcome |
|---|---|---|
| OpenCode (orchestrator, Luke) | docs/rfc/, .slim/clonedeps/, Plane AST board, community forks | Superseded by the System One programme's integrator lane |
| Claude (session started 2026-09-20) | priv/repo/migrations, priv/resource_snapshots, BPMN token/child-instance code + tests (AST Lane G) | Landed in 62e918c (2026-09-20) |
| Claude (session started 2026-09-21) | ~/capstone-demo only (CAP-2). In this repo: `.agents/logs/tool-gaps.log` and its row | Done — five package gaps logged |
| Claude (CAP-3, 2026-09-21) | ~/capstone-demo only (agent wiring). In this repo: its row only | Done — the capstone work continues in clinic-demo |
| Claude (Lane G restart, 2026-09-21) | `~/ash_bpmn` only (instance restart semantics). In this repo: its row only | Done — pushed to lukegalea/ash_bpmn main |
| OpenCode (2026-09-22) | Elixir 1.20 flip: mix.exs, devenv.nix, Dockerfile, ci.yml, docs/research/elixir-120-viability.md footer | Landed in f6d2934 and 2fe08df |

## Rules
- Do not edit another lane's claimed paths without a note here first.
- Enterprise-specific code stays in ash_enterprise; community repo forks
  never receive enterprise specifics.
- Plane work items (project AST) are the system of record for what is
  planned; the repository is the record of what has landed. Update Plane
  when a unit of work starts or finishes.
- Messages for another agent: append to `.agents/INBOX-<agent>.md`.
