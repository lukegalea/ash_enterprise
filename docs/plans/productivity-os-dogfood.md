# Productivity OS Dogfood — Epic Breakdown

Program plan: approved multi-board plan (durable copy: `local://productivity-os-dogfood-plan.md` workspace
artifact). This doc records the epic breakdown as executed. Design sources:
[ADR 0010](../adr/0010-*.md) (Meltano ingestion), [ADR 0011](../adr/0011-*.md) (Nango provider edge),
[ADR 0012](../adr/0012-openlineage-and-marquez.md) (OpenLineage + Marquez), ADR 0015 (approvals in Ash),
ADR 0035/0037 (event projections), `docs/dogfood_enterprise.md` §6–§11.

## Boards

| Board | Scope |
|---|---|
| **PROD** (`Productivity OS Dogfood`) | the vertical program. Epic items PROD-1..PROD-7 = E0..E6, labeled `Epic`. Note: the workspace plan gates Plane's Epics/work-item-types feature, so epics are labeled tickets, not typed epics (gap logged in `.agents/logs/tool-gaps.log`). |
| **AST** | one ticket per new extension repo: AST-143 `ash_open_lineage`, AST-144 `ash_acp`, AST-145 `amber_console`. |
| **CLIN** | demo-application tickets: at each PROD epic completion, one ticket per generalizable improvement, `Apply <improvement> to clinic-demo`. Standing DoD on every epic. |

## Epics

- **E0 — Program setup** (PROD-1): boards, epic items, AST tickets, a2a memory (`prodos_program`), this doc.
- **E1 — Ingestion foundation** (PROD-2; ADR 0010+0011): Oban-based ingestion runtime in ash_enterprise
  (thin layer, no new extension — dogfood §11 keeps Meltano as adapter workbench). Each pipeline is a wrapper
  job running a Meltano/Singer tap (start: `tap-postgres` → staging schema). Lands raw payloads immutably in a
  `SourceObject` resource (external system, external id, raw payload, cursor, fetched_at). Nango at the
  provider edge for Gmail/Calendar/Slack OAuth; connection id comes from the actor's linked-account resource,
  never an action argument. No lineage emission yet (hole rule; E2 adds ingestion Job events).
- **E2 — Lineage stream** (PROD-3; ADR 0012): new repo `lukegalea/ash_open_lineage` — Spark `lineage`
  extension + `Ash.Notifier` emitting OpenLineage RunEvents. `Run.runId` from host-configured
  `:correlation_provider` behaviour (`AshEnterprise.Platform.Correlation`); `parent` facet from depth;
  `Job` = domain + `{resource}.{action}`; `Dataset` from the `postgres do table end` declaration; custom
  `_producer` facet; `Req` HTTP transport + transport behaviour; OpenLineage spec 2-0-2 fixture conformance;
  leak test (no actor/tenant/value in facets); usage_rules published; consumed here as a GitHub dep.
  Ingestion wrappers emit ingestion Job RunEvents (input = source descriptor, output = staging table).
  Marquez via one compose file, internal network only. Naming alignment with AST-125 (ash_judgments lineage).
- **E3 — ACP foundation** (PROD-4; dogfood §7/§9): new repos `lukegalea/ash_acp` (ACP server wire adapter for
  Ash: JSON-RPC over stdio+HTTP; `initialize`, `session/new|load|prompt|cancel`, streamed `session/update`;
  permission requests map to host approval resources per ADR 0015 via `AshAcp.PermissionRequest` behaviour;
  per-actor action pruning with `Ash.can?` — AST-84 pattern; A2UI payloads carried from `ash_a2ui`, never
  re-defined; spec-fixture conformance, `@acp_version` pin; `terminal/*` deferred) and `lukegalea/amber_console`
  (Python + Textual + official ACP Python SDK; §9 model verbatim; A2UI terminal-safe subset only; amber
  monochrome theme; v1 acceptance: connect, list, detail, approve).
- **E4 — Productivity verticals** (PROD-5; §11): Calendar → Gmail → Slack, same slice shape: tap/adapter into
  E1's runtime (Gmail historyId cursor; Calendar sync tokens with 410-Gone resync; Slack Events + backfill;
  wrong-cursor = explicit sync-reset action); canonical resources (`Person`, `Account`, `Conversation`,
  `Message`, `CalendarEvent`, `Task/Commitment`, `Project`, `Artifact`) linked via `SourceObject` (v1 link on
  external id + email only); raw→canonical projection per ADR 0037, deterministic replay as correctness proof;
  A2UI surfaces through ash_acp, read-first, mutations draft-only (send = approval object, §5 capability
  transition); lineage RunEvents free via E2. Exit CLIN ticket: ingest→project→surface slice pattern.
- **E5 — Agent workflows** (PROD-6; §6): ash_ai typed tools over vertical actions (policies gate; OMP model →
  typed Ash action → result, never agent→agent); supervised `OmpSession` GenServer wrapping `omp --mode rpc`;
  resources `AgentSession`, `AgentRun`, `AgentMessage`, `ToolInvocation`, `Artifact` with
  `start_agent_run` / `send_agent_message` / `cancel_agent_run` / `approve|reject_tool_invocation` /
  `resume_agent_session`; approvals via ADR 0015 approval resource surfaced in amber_console as permission
  modals. "Morning brief" as an ash_bpmn workflow over projections (summarize via ash_ai, local Ollaya where
  possible; drafts only, every consequential action an approval). Exit CLIN tickets: agent-tool exposure;
  approval-in-terminal.
- **E6 — Daily-driver cutover** (PROD-7): operator's daily loop in amber_console; two-week dogfood log triaged
  into PROD tickets; `docs/roadmap.json` status updates + `mix ash_enterprise.roadmap`; HANDOFF.md
  "genuinely not done" refresh; CLIN demo-ticket sweep with the operator.

## Dependencies: E1 → E2; {E1, E3} → E4 → E5 → E6. Each epic leaves its repos green (`mix precommit` / `pytest`).

Design sources: [ADR 0010](../adr/0010-meltano-for-ingestion.md),
[ADR 0011](../adr/0011-nango-as-integration-hub.md),
[ADR 0012](../adr/0012-openlineage-and-marquez.md), ADR 0015 (approvals),
ADR 0035/0037 (projections), `docs/dogfood_enterprise.md` §6–§11.

## Operator involvement (minimized)

`/a2a-setup` once; `docker compose up -d` for the local services file (Marquez + Postgres + Nango, internal
network only); OAuth click-through for Google + Slack in Nango; ~5-min epic-exit spot checks in amber_console;
the two-week daily-driver log is using the product.
