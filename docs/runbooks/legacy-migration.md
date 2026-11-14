# Runbook: moving the legacy estate onto the platform

Written 2026-11-14 for q22 (moving off a legacy system while it keeps running) and q54 (what happens to a row
that fails to project). Code: `AshEnterprise.Legacy.User`, `AshEnterprise.Ledger.UserDrainWorker`,
`AshEnterprise.Ledger.UserIngestion`, `AshEnterprise.Legacy.UserBackfill`,
`AshEnterprise.Legacy.ReconcileWorker`, `mix ash_strangler.check`, `mix ash_enterprise.legacy.project`.
Tests: `test/ash_enterprise/legacy/reconcile_worker_test.exs`, `test/ash_enterprise/ledger/user_lifecycle_test.exs`,
`test/ash_enterprise/durability/ledger_announcement_test.exs`, `test/ash_enterprise/legacy/user_backfill_test.exs`.
The decision is ADR 0031.

This is one entity (`legacy.users`) on the same Postgres instance, and it is **read, projected and reconciled**,
not cut over. The legacy application keeps writing; this application reads what it wrote and keeps a table of its
own in step. Nothing here moves writes to the platform.

## The four phases, and where this estate is

| Phase | What it means | This estate |
|---|---|---|
| `:read_from_legacy` | The platform reads through a compatibility view; the legacy application owns every write. | **Here.** |
| `:dual_write` | A write goes to both sides. Needs every mapping to be invertible. | Not started. |
| `:read_from_new` | Reads come from the new table. One-way. | Not started. |
| `:cutover` | The legacy table is retired. | Not started. |

## The gate

```bash
devenv shell -- mix ash_strangler.check --strict
```

Fails when a mapping, the view DDL or the twin has drifted from what the resource declares. CI runs it in the end
to end job. Run it after any change to `Legacy.User`.

## The live path: the ledger and its drain

A trigger on `legacy.users` writes a durable row to `legacy_change_events` in the legacy application's own
transaction and sends a `pg_notify` wake. `AshStrangler.Listener` nudges `Ledger.UserDrainWorker`, which claims a
batch, hands each event to `Ledger.UserIngestion` (an idempotent upsert into `projected_users`, keyed on
`legacy_id`), and marks the batch, all in one transaction. A batch that fails is rolled back and retried (ten
attempts). The wake is only a hint: a cron entry enqueues the drain every five minutes, so a wake lost while the
listener was down costs delay, not delivery.

A hard `DELETE` in the legacy table is recorded in the ledger and **not** applied: ingestion skips it, because no
destroy action exists on the projected row at this phase.

## The starting state: the backfill

A row that has not changed since the ledger trigger was installed has no event, so it has never been projected.

```bash
devenv shell -- mix ash_enterprise.legacy.project
```

projects every non-archived row of the read model through `UserBackfill.project_row/1`. It is idempotent.

## The audit: the nightly reconcile

`AshEnterprise.Legacy.ReconcileWorker` runs at 03:23 UTC on the `ash_strangler_ledger` queue. It compares, in the
database and by checksum over key ranges:

1. the legacy table against the compatibility view (catches a stale view or twin); and
2. the view against `projected_users` for the estate's organization (catches a row the drain missed, refused or
   wrote wrongly, and a projected row edited by hand).

For every key range that disagrees it re-reads the legacy rows in that range through Ash and projects them through
the same `project_row/1`, then compares again.

What it does not do: it never deletes a projected row (a row whose legacy row was hard-deleted is **reported** as
orphaned), it never reads or writes another organization's rows, and it ignores archived rows (outside the
projection by the read model's rule).

**Reading the report.** A `[:ash_enterprise, :legacy, :reconcile]` telemetry event and one log line, both counts
and key ranges only, never a login, email or name. Fields: legacy and projected counts, `mismatched_ranges`,
`repaired`, `refused`, `orphaned`, `converged?`. `converged?: false` after a repair means a row was refused (see
the `refused` count and the ingestion's own log for the cause) or the drift is in the view, not the projection.
Drift is telemetry only for now: no stored run record and no finding.

**On demand**, inside the running node:

```elixir
AshEnterprise.Legacy.ReconcileWorker.run(repair?: false)   # report only, writes nothing
AshEnterprise.Legacy.ReconcileWorker.run()                 # report, repair, report
```

## What a cutover would still need

- `full_name` is a concatenation of `first_name` and `last_name`, and no rule splits it back: not invertible.
- `legacy_state` collapses five legacy values onto two lifecycle statuses: `lifecycle_status` is not invertible.
- `company_id` is unmapped; at this phase the estate is one tenant by constant, and it becomes a boundary only
  at the step that maps it.
- `:read_from_new` is one-way: once reads move, a legacy write no longer shows.
- A real `:dual_write` step for `Legacy.User` needs the three points above resolved first.
