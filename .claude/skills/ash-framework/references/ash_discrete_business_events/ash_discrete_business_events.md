<!-- SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events> -->
<!-- SPDX-License-Identifier: MIT -->

# Usage rules

Rules for working with `ash_discrete_business_events`, maintained for
[`usage_rules`](https://hex.pm/packages/usage_rules) sync. The package
contract below is binding on every change — in this repository and in
consumers. (Grows with each slice; what is here is already binding.)

## What the package is

The canonical discrete business-event ledger: `SourceRecord` raw landing
with temporal version history (BIZEV-3), the dedicated locked-and-chained
event ledger with per-region commit-order sequences and its simulation
twin (BIZEV-4, BIZEV-10), mappings-as-data with per-row provenance
(BIZEV-5), job-granular lineage (BIZEV-6), the Salesforce Bulk 2.0
adapter and fixture corpus (BIZEV-7), temporal projections over the
ledger (BIZEV-8), corrections as superseding events (BIZEV-9), raw-layer
retention and erasure (BIZEV-12) and the BPMN trigger bridge (BIZEV-13)
— the land → map → ledger boundary external SaaS history enters the
platform through.

## What it never does — do not make it

- **Never hand-roll validity bookkeeping.** Any new `valid_from`/
  `valid_until` columns on BIZEV resources are a design error (design §4).
  `SourceRecord`'s validity is the temporal extension's `valid_at` period
  (`strategy :context`); the ledger is create-only and forbidden-by-mandate
  from being temporal at all. Corrections are NEW ledger rows via
  `supersedes_event_id` — never rewrites, never validity ranges.
  `docs/REVIEW.md` rejects this on sight.
- **Never merge regions silently.** Chains, advisory locks, sequences and
  cursors are per-region, structurally (§6). A global chain or global
  cursor is a silent merge — the partition is the honesty. Consumer reads
  require a region; the one gated exception (`cross_region_read`) writes
  a disclosure row per queried region before scanning. Delivery
  idempotency is per region too — same delivery_key, different region,
  two rows.
- **Never write the ledger except through `record`.** Update/destroy
  actions do not exist and the immutability trigger refuses them at the
  database; the stock AshEvents create is removed. Correct a wrong entry
  by recording a new one with `supersedes_event_id`.
- **Never put cursors in job args.** Cursors are data: on SourceRecord
  rows and sync-run records (§2.3). `reset_cursor` is an explicit
  action; wrong-cursor conditions are operator actions, never silent
  rewinds. A reset is a visible historical event (the temporal split),
  never an erasure.
- **Never treat external ids as identities.** Subject/actor rows carry
  descriptors (`type`, `external_id`, `stream`/`display`) — linking to
  internal entities is projection/entity-resolution work, never done at
  land (VendorPM Law 1, ADR 0017). The SourceRecord's `external_id` is
  an idempotency key inside the identity tuple, not a join key.
- **Never ship a concrete resource module for hosts to adopt.** The
  resources are resource macros (`use AshDiscreteBusinessEvents.Resources,
  :source_record` / `{:ledger, opts}`) so hosts instantiate them on their
  own base and their policies apply natively (§1.1).
- **Never emit per-row lineage.** Lineage is at job granularity — the sync
  run or webhook batch is the unit (§3). The run-id derivation is
  exported and shared by construction, and the leak rule (no actor,
  tenant, customer or filter values in emitted events) is a mechanized
  acceptance test.
- **Never silently degrade on budget exhaustion.** Rate budgets are
  surfaced data; exhaustion is a visible FAIL — the feed pauses, it does
  not degrade (§7).
- **Never let simulated events touch real consumption.** The twin is a
  separate module and table (§5.6); sim rows are unmistakable by shape
  (`simulated: true` + `simulation_run`). Projectors, rebuilders, cursors
  and chains bind to the module — no query-filter discipline to forget.

## Working with the raw layer (BIZEV-3)

- Instantiate `SourceRecord` via the resource macro on YOUR base — never
  adopt a concrete module; the macro is what lets your policies govern
  the land and read actions (§1.1).
- Land through `land/1` only. It is the typed boundary: admission
  (refuse-until-tagged, tag must admit into the target region) and,
  later, ownership/tenancy/lineage attach here. No staging-table side
  doors.
- Landing is idempotent — re-running a sync is safe: identical content
  (payload AND cursor) is a no-op; changed content opens a new period.
  Never write an upsert-refresh-in-place path beside it; that is the
  exact defect ADR 0049 names.
- The land decision compares the version valid **at `fetched_at`** — a
  late duplicate of already-observed content is a no-op. Landings whose
  `fetched_at` precedes an identity's known history are refused with
  `SourceRecord.BackdatedLanding` (taps deliver in cursor order). Late
  arrivals and restated history are handled downstream, as superseding
  ledger events (BIZEV-9) — never by forcing a backdated landing.
- Residency is fixed at admission. Content changes re-open periods;
  they do not re-litigate the tag.
- As-of questions go through `at/5` (index-backed containment), never
  by re-reading and filtering in the consumer.
- Identity attributes must be globally unique across concurrent tests —
  two tests landing the same external id deadlock on the exclusion
  constraint's row locks (the ash:testing deadlock rule).
- The raw table is RANGE-partitioned by `fetched_at`, monthly (BIZEV-12).
  ash_postgres codegen does not model partitioning, so the partitioned
  parent and its DEFAULT partition are a hand-maintained migration in the
  host (`priv/test_repo/migrations/20261017100000_partition_source_records.exs`
  is the shape). The identity exclusion is enforced per partition.
- Create explicit months with `Retention.ensure_partition!/2` — it adds
  the per-partition identity exclusion. Rows outside any explicit month
  land in the DEFAULT partition, which `purge_before/3` never drops.

## Working with the ledger (BIZEV-4)

- Record through `record/1` only. `sequence` order is commit order per
  region because the record path takes the advisory lock before insert —
  never add a write path that skips the lock, and never consume the feed
  on anything but `sequence` (`feed/2` resumes after a high-water mark).
- `action_type` is the substrate's replay routing, derived from the
  consumer's action of the kind's name (create/update) — not caller
  input. `action` carries the event kind; projectors match
  `project "kind"` (the atom form).
- The immutability trigger is part of the contract: TRUNCATE stays
  allowed (a reset is conspicuous; one altered row is not), and the
  chain is what detects quiet edits — run `mix bizev.verify_chains`
  after any load/backfill that disabled triggers.
- The primary read (`:read`) is machinery-only (AshEvents' replay scans
  through it); consumers use the region-scoped reads.
- Correct a recorded fact by recording a new event whose
  `supersedes_event_id` points at the current truth for that subject and
  instant (BIZEV-9). `Ledger.Corrections` is the truth-point register:
  same point + same data folds away, same point + different data is a
  superseding event. Never re-record identical content to "refresh" it.

## Working with lineage (BIZEV-6)

- Emit through `Lineage.run/3` (START, COMPLETE, FAIL on raise) around
  the whole batch — one sync run or webhook batch is one job. Never
  register the AshOpenLineage notifier on a BIZEV resource.
- Name jobs and datasets through `Lineage` (`job/2`, `raw_dataset/2`,
  `ledger_dataset/1`, `rules_dataset/2`) — never hand-build the strings.
- Operational runs use `Lineage.run_id(:operational)` (the host
  correlation id); replays and backfills use the content-derived
  `Lineage.run_id(%{purpose:, ledger_range:, mapping_versions:})`.
- Stream ranges go out as facet counts (`:counts`), never boundary
  values; actor, tenant, customer and filter values never go out at all.
- Parent run ids cross process boundaries as data:
  `RunContext.put_parent/2` (string key in Oban args),
  `RunContext.enter_from_args/2` at worker entry, `RunContext.fan_out/3`
  for Task fan-outs. Host correlation scope is wired with
  `config :ash_discrete_business_events, :scope_establisher, {mod, fun}`
  (arity 2: `(parent_id, fun)`).

## Working with adapters (BIZEV-7)

- A source's `adapter` must implement every `Adapters.Adapter` callback
  or the host does not compile; one `auth` edge per source.
- Run syncs through `Adapters.Sync.run/1` with the cursor read from your
  sync-run record, and persist the returned `cursor`. Budget exhaustion
  returns `{:error, %Adapters.BudgetExhausted{landed:, cursor:}}` — the
  job fails visibly and the feed pauses at that cursor.
- Tokens come from the configured `Adapters.AuthProvider`; a connection
  id is never an action argument. CI runs adapters against the fixture
  transport, never a live org.

## Working with projections (BIZEV-8)

- Declare projectors with `use AshDiscreteBusinessEvents.Projections`
  (`name:`, `event_log:`, `projection_resource:`) and drain them with
  the projector's `drain/2` — the package-owned, per-region drain over
  `feed`. Never run the engine's Server over the ledger: it scans by
  global id, a silent cross-region merge.
- `project "kind"` matches the ledger's `action` (the event kind's atom
  form); the handler sees the whole ledger row.
- Declare `temporal` on the projection resource to get periods: the
  drain writes `as_of event.occurred_at`, so late arrivals and
  corrections reopen history at truth time.

## Working with the simulation twin (BIZEV-10)

- Simulated events are recorded on `<Ledger>.SimulationEvent`, whose
  `record` requires a `simulation_run` label — never on the real ledger.
- Drain a simulation through the projector's `drain_simulation/3` (or
  `Projections.Drain.simulation/4`); its checkpoints are keyed
  `sim:<name>.<region>:<run>`. Never give a real projector a name that
  starts with `sim:` — the prefix is reserved by convention and nothing
  refuses it.
- Any surface listing event history labels simulated runs; read them
  with `AshDiscreteBusinessEvents.simulation_runs/1,2` (the second
  argument is the read's options — a multitenant twin needs `tenant:`).
- A ledger on your own base should pass that base as
  `simulation_base: {MyBase, use_opts}`, so the twin gets your tenancy,
  changes and policies too. `use_opts` must bring both
  `AshEvents.EventLog` and `AshDiscreteBusinessEvents.Ledger.Extension`;
  the twin refuses to compile otherwise. Without the option the twin is
  a bare resource with no policies of yours.

## Retention & erasure (BIZEV-12)

- Purge with `Retention.purge_before/3` (`before:`, `region:`,
  `confirmed: true` — it refuses without the opt-in). Whole monthly
  partitions drop; each drop records a `:"retention.partition_purged"`
  tombstone with structural facts only.
- Erase a subject with `Retention.erase_subject/4,5`: the
  `:"retention.subject_erased"` tombstone is recorded first, then the
  raw rows are deleted. Erasure is local — the next sync re-lands the
  subject's current state as new history.
- Never put payload values in a tombstone.
- A multitenant or owned ledger passes `record_opts:` (`tenant:`,
  `actor:`, `authorize?:`) and `context:` to either action. A host whose
  erasure is its own builds the same tombstone with
  `Retention.tombstone/5` and records it through its ledger's `record`.

## The BPMN trigger bridge (BIZEV-13)

- Wire a handler with `config :ash_discrete_business_events,
  :trigger_handler, MyHandler` implementing
  `Triggers.Handler.nudge/1`. It receives the ledger row; the event kind
  is in `action`.
- Nudges are best-effort; run `Triggers.sweep/3` periodically for
  completeness. Delivery is at-least-once, so handlers must be
  idempotent. Simulated rows never nudge.
- Process correlation rides the row's `process_ref`, set from the
  mapping's `process_key` (a payload path) or by the caller.

## Working with the DSL

- Sources and mappings are declared on a host module
  (`use AshDiscreteBusinessEvents, domains: [...]`); read them back
  through `AshDiscreteBusinessEvents.Info` — never by grepping the host
  module or re-parsing source.
- The DSL vocabulary is closed and schema-verified: an unknown option is
  a compile error. Extend it by amending the schema and citing the design
  section — never by accepting `:any`-typed escape hatches.
- Mapping targets named like direct personal data (`email`, `phone`,
  `ssn`, `tax_id`, … — the list is in `Transformers.VerifyMappings`) are
  refused at compile time. Keep PII in the raw layer and name the gap
  with `unmapped_because`. The guard catches obvious names only; it is
  not a PII classifier.
- `region` is required on every source (§6). A source without a region
  has no honest place to land.

## Status

BIZEV-2 froze the contracts; BIZEV-3 delivered the raw layer; BIZEV-4
the ledger; BIZEV-5 the mapping engine — the closed operator vocabulary,
content-hashed `MappingVersion` artifacts (draft → validate → activate),
the pure apply path, and the classifier seam; BIZEV-6 lineage; BIZEV-7
the Salesforce vertical and fixture corpus; BIZEV-8 projections;
BIZEV-9 corrections; BIZEV-10 the simulation twin's isolation contract;
BIZEV-12 retention and erasure; BIZEV-13 the BPMN trigger bridge. The
README's "Status" table is the slice list. The row shapes are pinned
by the fixture-pinned contract tests in `test/` — amending them requires
amending those tests and citing the design section that motivates the
amendment.
