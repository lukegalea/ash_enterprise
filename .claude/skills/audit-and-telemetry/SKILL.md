---
name: audit-and-telemetry
description: "Use when working with the audit trail, correlation ids, telemetry or OpenTelemetry in this application — how events get recorded, how to query them, and what is deliberately not automatic."
---

# Audit and telemetry

Both are inherited from `AshEnterprise.Platform.Resource`. A resource is audited
and instrumented by virtue of being a platform resource; there is nothing to
remember when adding one.

## The audit trail

One central log — `AshEnterprise.Audit.EventLog` — not per-resource version
tables. See `docs/adr/0002-ash-events-over-paper-trail.md` for the reasoning.
Compliance questions are overwhelmingly cross-entity ("everything user X did last
Tuesday"), which a central log answers with one query.

Shaped after the Dataverse `audit` entity:

| Column | Meaning |
|---|---|
| `action` | The **action name** — `assign`, `assign_to_business_unit` |
| `action_type` | create / update / destroy |
| `resource`, `record_id` | What changed |
| `user_id` | Who, when it was a human |
| `metadata["system_actor"]` | Who, when it was not |
| `metadata["correlation_id"]` | Which operation this belonged to |
| `data`, `changed_attributes` | The change itself |

### Prefer named actions

An audit entry records the action name, so `assign_to_business_unit` tells a
reader what happened where a generic `:update` does not. When an action has
meaning, give it a name — this is the single highest-leverage habit for making
the log useful later.

### Correlation

One user action routinely writes several rows. `metadata["correlation_id"]` groups
them, so "show me everything that happened in this operation" is one query. It is
stamped automatically per request.

⚠️ It does **not** cross process boundaries. Work handed to a `Task` or an Oban
job starts a new correlation unless you pass it:

```elixir
correlation = AshEnterprise.Platform.Correlation.id()
Task.start(fn ->
  AshEnterprise.Platform.Correlation.with_correlation(correlation, fn ->
    # audit events here join the originating operation
  end)
end)
```

### Non-human actors

Use a named `SystemActor`, never a nil actor:

```elixir
Ash.create!(changeset, actor: AshEnterprise.Platform.SystemActor.oban())
```

"The nightly job did this" and "we failed to record who did this" are different
findings. A null `user_id` alone cannot tell them apart; the `system_actor`
metadata can.

### Reading the log

Requires a **global read grant** on the event log — reading the audit trail is
itself privileged, because it reveals the existence and history of records the
reader may not otherwise see.

## Telemetry

`Ash.Tracer` → `OpentelemetryAsh` → OTLP, configured once. Every action, query,
changeset, validation and calculation becomes a span with no per-resource wiring.

`traces_exporter` is `:none` by default — exporting by accident is worse than not
exporting. Set `OTEL_EXPORTER_OTLP_ENDPOINT` to turn it on.

Metrics are declared **per domain** in `AshEnterpriseWeb.Telemetry`, which is the
granularity Ash emits at. Adding a resource needs no change here; **adding a
domain does**. That is the one place this is not automatic.

## Known gaps

There is no retention or purge policy, and an append-only audit log is exactly
what a GDPR erasure request collides with. Named in
`docs/manifesto/07-what-we-do-not-have.md` rather than pretended away. Before
production: time partitioning and a retention story.
