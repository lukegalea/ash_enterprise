# ADR 0036 — Converge process triggers onto projection checkpoints

- **Status:** accepted
- **Date:** 2026-09-17
- **Accepted:** 2026-09-18

> Renumbered from 0035 on acceptance. The number was taken while this sat open, by
> [0035](0035-compliance-is-projected-from-events.md) — which is the other consumer of the
> same projections engine, and the reason the duplication this ADR retires was worth noticing
> in the first place.

## Context

The process domain (`ash_bpmn` / `ash_enterprise`) carries its own event-consumption
apparatus: `Trigger`, `TriggerCursor`, and `TriggerDispatch` — per-tenant cursor
tracking that wakes process instances when events they wait on are committed. (Those three
have since been renamed `Subscription`, `Cursor` and `Dispatch`, and moved into
`AshEnterprise.Bpmn`; the substance is unchanged and the old names are kept here as written.)
Independently, `ash_events_projections` grew a generalized version of the same
machinery: a `Checkpoint` resource (`last_seen_event_id` per projector), a
`DeadLetter` queue with replay, gap detection for ordering hazards, a
`NotifyProjectors` commit-broadcast fast path with checkpoint drain as the
recovery net, and blue/green rebuild. The projections engine runs four
projectors in ScribbleVet production over a shared `ash_events` log.

Two engines now solve the same problem: consume a committed event stream
durably, exactly-once-effectively, with recovery. The design dialogue of
2026-09-17 (see corpus bundle 31) flagged the duplication explicitly:
"`Checkpoint` is `TriggerCursor` generalized. You should consider converging:
one event-consumption engine instead of two."

One ordering caveat drives part of the decision: `ash_events_projections`'
own `Operations.Gaps` module documents the bigserial late-commit hazard
(low ids committing after high ids). Our per-tenant advisory-lock hash chain
is the stronger ordering primitive; the convergence must not downgrade it.

## Decision

The process domain stops owning cursor machinery. `Trigger`/`TriggerCursor`/
`TriggerDispatch` are retired in favour of treating each BPMN event-wait as a
projector registration on the `ash_events_projections` engine:

- A process instance waiting on an event is a projector grain; the engine's
  `Checkpoint` replaces `TriggerCursor`, `DeadLetter` replaces `TriggerDispatch`
  failure handling.
- Wake-up uses the existing fast path: `NotifyProjectors` broadcast for
  latency, checkpoint drain sweep as the net. No new wake-up mechanism.
- Checkpoints key off the per-tenant advisory-lock hash chain, not raw
  bigserial ordering — preserving the stronger primitive (and superseding the
  upstream `Gaps` mitigation).
- Dispatch remains at-most-once per wake with idempotent handlers, exactly as
  projector handlers already are.

New code reduces to a projector-behaviour adapter over the existing
process-trigger semantics plus a data migration mapping live `TriggerCursor`
rows to `Checkpoint` rows.

## Does it consume ActorContext?

Indirectly, unchanged. Event consumption is system-actor work today and remains
so; the swap is below the actor layer. Dispatch into process-instance actions
still resolves actors through ActorContext as it does now — the engine is not
actor-aware and does not need to be.

## Consequences

One event-consumption engine to operate, monitor, and teach: DLQ, lag,
rebuild, and verify tooling apply to process wake-ups for free. Process
definitions gain projection blue/green versioning for free.

Costs: `ash_bpmn`/process domain takes a dependency on `ash_events_projections`
(today the coupling is only to `ash_events`). The migration must be exact — a
lost cursor row is a stuck process instance, so the cutover runs dual-read
until checkpoints are proven lag-zero.

## Reversal

Reversal is cheap while the old apparatus is kept behind a behaviour for one
release: re-point the process domain at the legacy `TriggerCursor` reader and
drop the projector registrations. The adapter and the cursor→checkpoint
migration are the only files involved. Once `Trigger*` tables are dropped,
reversal becomes a rewrite — which is the point of keeping them one release
longer than comfortable.
