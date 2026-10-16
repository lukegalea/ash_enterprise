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
twin (BIZEV-4), and mappings-as-data with per-row provenance (BIZEV-5) —
the land → map → ledger boundary external SaaS history enters the
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
  `fetched_at` precedes an identity's known history are refused
  (taps deliver in cursor order; backdated reconstruction is BIZEV-9).
- Residency is fixed at admission. Content changes re-open periods;
  they do not re-litigate the tag.
- As-of questions go through `at/5` (index-backed containment), never
  by re-reading and filtering in the consumer.
- Identity attributes must be globally unique across concurrent tests —
  two tests landing the same external id deadlock on the exclusion
  constraint's row locks (the ash:testing deadlock rule).

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

## Working with the DSL

- Sources and mappings are declared on a host module
  (`use AshDiscreteBusinessEvents, domains: [...]`); read them back
  through `AshDiscreteBusinessEvents.Info` — never by grepping the host
  module or re-parsing source.
- The DSL vocabulary is closed and schema-verified: an unknown option is
  a compile error. Extend it by amending the schema and citing the design
  section — never by accepting `:any`-typed escape hatches.
- `region` is required on every source (§6). A source without a region
  has no honest place to land.

## Status

BIZEV-2 froze the contracts; BIZEV-3 delivered the raw layer. The ledger
lands in BIZEV-4, the mapping engine in BIZEV-5. The row shapes are
pinned by the fixture-pinned contract tests in `test/` — amending them
requires amending those tests and citing the design section that
motivates the amendment.
