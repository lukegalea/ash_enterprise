# ADR 0062 — Planning proposes; declarations and people commit

- **Status:** accepted — built. Phase 2 (the kernel and the personal-week planner) landed 2026-11-06: needs_input honesty, proven-optimal governed solve, dual-checked candidates, approve/apply writing schedules as the person.
- **Date:** 2026-11-04
- **Related:** ADR 0038 (models observe), 0040 (record, don’t recompute),
  0046 (declarations are output contracts), 0047 (learning proposes),
  0049 (temporal validity), 0055 (governed invocations), 0056 (public package boundary)

## Context

Constraint solving is missing from the platform, but the surrounding machinery exists:
judgments admit observations, DMN selects requirements, rules/compliance evaluate eligibility,
BPMN accepts and executes work, BIZEV separates simulated futures, lineage records structural
provenance, and temporal resources carry effective-dated state. PR #147 is adding extraction
with the same honest input rule: unresolved values must remain unresolved.

Solverl 1.1.2 is active but was last tested against MiniZinc 2.4.3; current MiniZinc is 2.10.1.
No resource-limited external-binary solver pattern exists in the platform yet.

## Decision

`ash_planning` is a thin proposal kernel over adopted solver infrastructure:

1. Models are immutable MiniZinc model/checker documents plus an independent Elixir validator.
   The first version does not compile a universal Spark constraint DSL to MiniZinc.
2. Solve outcomes, completion, optimality, validation, freshness, disposition, and world axes are
   separate. No timeout is reported as infeasibility and no checker is reported as an optimality
   certificate.
3. Required unresolved or unknown inputs produce a needs-input/unresolved assessment. Forecasts
   remain scenarios on the simulation twin.
4. Every run consumes the one shared `AshOpenLineage.Snapshot` envelope and stores a sealed
   canonical payload hash. Replay reconstructs and revalidates; it does not promise repeated
   identical search.
5. The public package contains only the kernel, adapters, behaviours, resource macros, generic
   validators, and synthetic fixtures. Hosts own models, authority, actions, policies, data,
   and private tuning.
6. Solver processes are one supervised session per run, cancellable by direct OS pid/process
   group, and limited by wall/solution/memory/CPU controls. Heavy solves run in Coder
   workspaces. Processes are never killed by pattern.
7. Authorization decides who may prepare, inspect, approve, or apply a plan. It is never a
   solver constraint.
8. ash_bpmn owns human acceptance and any multi-step execution; existing Ash actions remain the
   only way operational state changes.

## Does it consume ActorContext?

Yes, at preparation, candidate reading/approval, and application. Every read and write goes
through ordinary Ash policies and tenant scope; no policy check queries. The solver receives a
bounded problem document only, never credentials, tokens, actor context, or database access.
Completeness (`authorized subset` versus `declared complete`) is explicit in the snapshot, so a
personal plan is never presented as a complete fleet/tenant plan.

## Consequences

- A feasible, checked candidate is auditable and replayable, but the platform never claims the model faithfully represents reality or that a checked solution is optimal without a solver optimality certificate.
- Hosts must author and review model/checker/validator triples before value appears.
- A second host can adopt the capability without adopting another host's private
  models.
- Solver failures and limits are operational states, not authorization failures.

## Reversal

Remove the Planning domain and host bindings, then remove the package dependency. No operational
resource interprets candidate rows, so unapplied candidates are inert. Reversing the shared
snapshot means removing the value type from ash_open_lineage after extraction and planning stop
using it; existing Run rows retain their stored envelopes and digests.
