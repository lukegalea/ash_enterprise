# ADR 0051 — Business events are derived from the canonical store, into a chained ledger

- **Status:** accepted (2026-10-12), implemented — see the implementation notes (2026-10-12, 2026-10-18)
- **Date:** 2026-10-12

## Context

The dogfood deployment lands Gmail, Slack and Google Calendar into `AshEnterprise.Ingestion.SourceObject` (sealed,
operator-only) and projects them into the canonical store (`AshEnterprise.Canonical`: `CalendarEvent`,
`Conversation`, `Message`, `Person`). That store holds the independent data: what each system says, normalized. Nothing
held what *happened*: that a meeting was moved, that a message arrived, that a conversation started. Every consumer
that wanted a timeline would have to diff rows itself.

Luke's direction (2026-10-12): adopt `ash_discrete_business_events` (BIZEV) so dogfood has an event stream, and "start
deriving info on top of the independent data and emitting new facts". Not bpsim yet.

What existed, verified 2026-10-12:

- **BIZEV on `main`** (github `lukegalea/ash_discrete_business_events`, `8f707f6`): BIZEV-2/3/4 landed. The `:ledger`
  resource macro emits a dedicated `AshEvents.EventLog` whose rows are business events: a per-region advisory lock taken
  before insert (so `sequence` is commit order within a region), a per-region SHA-256 chain written by a trigger, an
  immutability trigger, delivery idempotency, region-scoped reads, a commit-order `feed`, and a simulation twin. The
  mapping engine (BIZEV-5) is on an unmerged branch; adapters (BIZEV-7) and corrections (BIZEV-9) are not started.
- **The BIZEV design** (`system-one-program/research/bizev-design.md`, §8) names ash_enterprise the integrator, with the
  dogfood's `SourceObject` and projectors left in place and migrated one vertical at a time, later.
- **`AshEnterprise.Ledger`** already exists and is something else: the strangler's change-data ledger over the legacy
  schema (`UserIngestion`, `UserDrainWorker`). Rows changed in a database, not facts about a business.
- **ADR 0024's erasure**: canonical content (`title`, `location`, `body`, `subject`, `participants`) is sealed under the
  erasure scope of the linked account it came through; a shred destroys the key. Structure (ids, times, statuses,
  directions, foreign keys) stays in the clear by design, and so do `Person` names and addresses (a documented gap).

Two package defects surfaced on adoption and were fixed upstream first (BIZEV PR #3, `e4c3c60`): `record` did not pass
its caller's actor, tenant or `authorize?` to the internal append, so a multitenant host could not insert; and it raised
on any call that omitted an optional argument. `ash_events` was also promoted from a test-only to a real dependency of
the package, since the ledger compiles against it.

## Decision

**1. Adopt the BIZEV ledger, on the platform base, beside what exists.** `AshEnterprise.BusinessEvents.Ledger` is the
`:ledger` macro on `AshEnterprise.Platform.Resource` (tables `business_events` / `business_simulation_events`), in a new
domain `AshEnterprise.BusinessEvents`. BIZEV's `SourceRecord` and mapping DSL are not adopted yet: `SourceObject` stays
the raw layer and the canonical projectors stay the mapping, as the BIZEV design's §8 says. The new domain only adds the
facts on top; nothing is duplicated. The name avoids `AshEnterprise.Ledger`, which keeps meaning the strangler's.

**2. Facts are derived from canonical writes, not from raw payloads.** A change
(`AshEnterprise.BusinessEvents.Changes.Derive`) on `CalendarEvent` and `Message`'s `upsert_from_source` hands the
written row to a pure mapping (`AshEnterprise.BusinessEvents.Derivation`) and records what it derives, **in the same
transaction** as the canonical write. Every projector writes through that action, so every projection, present and
future, emits without knowing the ledger exists, and a canonical row and its facts commit together or not at all.

The first facts:

| Kind | Derived from | `occurred_at` |
|---|---|---|
| `calendar_event.scheduled` | first sight of a live event, or a cancelled one reinstated | the row's `updated_at` |
| `calendar_event.changed` | `starts_at`, `ends_at`, `status` or `organizer_id` differs from the last fact (`data.changed` names which) | the row's `updated_at` |
| `calendar_event.cancelled` | status became `:cancelled` | the row's `updated_at` |
| `message.received` / `message.sent` | a message, by direction | `sent_at` |
| `conversation.started` | the first message observed in a conversation (a fact no source states) | that message's `sent_at` |

A calendar event's `occurred_at` is the canonical write time, because the projection does not carry Google's `updated`
yet; an honest knowledge-time proxy beats an invented truth time. The mapping is declared as data in `Derivation`, and
its SHA-256 is every row's `provenance.mapping_version_hash`; `provenance.source_record_id` is the canonical row's id.

**3. Subjects are source identities.** `subject_stream` is the external system (`:google_calendar`, `:calendar`,
`:gmail`, `:slack`) and `subject_external_id` its external id, not the canonical UUID: deleting the canonical rows and
replaying the projection mints new UUIDs, and a fact keyed on one would be re-derived as new. The UUID rides in `data`.
Native rows (no external identity) derive nothing.

**4. Idempotent, so live emission and backfill converge.** Every fact has a delivery key (a SHA-256 of ids only).
Message and conversation facts are once-only (`kind` + subject). A calendar event's key is its subject plus the id of
the last fact about it, read back with the ledger's own `by_subject`: a change derived twice from one predecessor
records once, and a change back to an earlier state is still a new fact. A replay, a resync, a re-projection after a
shred, and `AshEnterprise.BusinessEvents.backfill/0` all record only what is missing.

**5. As the owner, in the tenant, owner-only.** Rows carry `organization_id` (attribute multitenancy) and are
`:user_owned` by the owner of the canonical row they came from. The ledger is owner-only
(`AshEnterprise.Security.Privilege.owner_only?/1`), as `Message` is: no role reaches another user's facts. Recording is
machinery, like the projection that triggers it (`authorize?: false`); reads are real authorization. Because BIZEV's
`record` accepts a fixed argument set, the owner (and the tenant) ride in the `context` argument, which is a chained
column, and `AshEnterprise.BusinessEvents.Changes.StampOwner` copies them onto the ownership columns. So *whose* fact
it is is tamper-evident along with the fact; a context naming another tenant than the write's is refused.

**6. Shred-safety by construction (ADR 0024).** A row carries only what the canonical row it came from holds **in the
clear**: ids, timestamps, statuses, directions, a conversation's `kind`, and the row's `erasure_scope_id`. Never a sealed
field, never a digest of one (a hash of a short title is a dictionary away from the title, and it would outlive the
shred), never a person's name or address, and never the participant or attendee lists (sealed or not projected).
`actor_display` is never set; a message's actor is the sender's canonical `Person` id. Consequently a shred changes
nothing here, and both of its promises hold without a ledger-side mechanism:

- **The chain stays verifiable**: no chained byte depended on the destroyed key, and the immutability trigger means the
  shred has nothing to rewrite.
- **Nothing readable is left**: nothing sealed was ever written. A reader that wants to know which facts now point at
  shredded content follows `data.erasure_scope_id` to the scope's status.

The alternative — sealing `data` under the source's scope — was rejected: the chain hashes `data`, so the ciphertext
would be chained, fine, but the ledger would then hold content whose only protection is a key, and every consumer of
the feed would need the vault. Facts that never contained content are simpler and stronger.

**7. Region and residency are configuration.** `region` (one of `ca`, `us`, `eu`, `local`; `BUSINESS_EVENTS_REGION`)
partitions the chain, lock and feed; `residency_tag` is the canonical store's zone (`CANONICAL_ZONE`), because the facts
are derived from that store and live where it does. A row's region is permanent; set it before the first fact.

## Does it consume ActorContext?

For reads, yes and fully: the ledger inherits the platform policy set, so `by_region`, `feed`, `by_subject` and `by_id`
are filtered by `RoleGrant` on the precomputed context, at `:basic` depth only. For writes, no, deliberately: recording
runs as machinery inside a projection's transaction and takes its owner from the row it derives from, not from the
caller. The package's generic actions (`record`, `cross_region_read`) map to the `:read` verb, and at the only depth a
user can hold here (`:basic`) `RoleGrant` answers with a filter, which Ash refuses to evaluate for a generic action: a
user's direct `record` call raises (pinned by a test) rather than recording. It raises `Ash.Error.Unknown`
("Cannot use filter checks with generic actions"), not `Forbidden` — true of every generic action on a `:user_owned`
platform resource for a non-`:global` grant, and worth a platform fix of its own. Nothing exposes either action.

> **2026-10-14.** Fixed at the platform: for a generic action the grant checks no longer answer with a filter.
> `RoleGrant` authorizes it only on a `:global` grant (a generic action has no row for a narrower depth to reach),
> and `SharedWithActor` and `HierarchyGrant` contribute `false`. Nothing widened — the raise already refused these
> calls — but a direct `record` is now `Forbidden`, and `Ash.can?/3` answers `false` instead of raising, which is
> what the ACP command palette prunes with: a user holding any narrower-than-global grant on a palette action's
> resource could not open an ACP session at all.
>
> **2026-10-15.** A generic action a resource declares `self_service` is the one exception: any active member of the
> tenant may run it with no grant ([ADR 0052](0052-self-service-actions.md)). Only `MorningBrief.compose_today`
> declares one; the two actions here do not.

## Consequences

- Dogfood has an event stream: the owner's commit-ordered feed (`Ledger.feed(region, after_sequence: n)`) of what
  happened across mail, Slack and calendar, the substrate the next wave's UI and derived facts build on.
- A projection now takes the region's advisory lock for the length of its write transaction. Writes in one region
  serialize on it, as the design intends; at dogfood scale this is invisible. A sandboxed test holds the lock for the
  whole test, so tests default `emit?` to false and the ledger's own tests (and the erasure end-to-end test) are
  `async: false` and switch it on.
- A ledger failure fails the canonical write with it. The projectors already reduce a failed write to field names
  (`Projections.Write`), and a fact holds no content, so the failure carries none.
- Facts are only as good as the canonical model: no attendee or participant facts until those are first-class, clear
  links; no provider-time `occurred_at` for calendar until the projection keeps Google's `updated`.

## Known gaps

Closed on 2026-10-18 (see that implementation note): the simulation twin on the platform base, corrections of a
conversation's start, and a tombstone fact on a shred. Retention was decided rather than built (below).

- **`cross_region_read` is closed, deliberately (decided 2026-10-21).** This host runs one region, and nothing exposes
  the action. It stays closed on both sides, and `ledger_test.exs` ("cross_region_read is closed") pins both:
  - **Users:** a generic action needs a `:global` grant, and the ledger can't be granted wider than `:basic`, so no
    role reaches it, an Administrator included.
  - **Machinery:** the system actor's bypass lets the action run, but its disclosure rows carry no owner, so
    `StampOwner` refuses them and the transaction rolls back. Nothing lands.

  **When a second region exists,** a disclosure belongs to the stream of the region that was read, not the caller's.
  It is readable by that organization's administrators, and the caller is recorded as the actor. Owner-only on the
  caller would hide the alarm from everyone but the operator who raised it. Opening the door then takes two changes:
  upstream, the package's action passes its caller's context to the append, as `record` already does; here, the
  owner rule above, with the two tests rewritten to prove it.
- **Retention is decided: the ledger is append-only and is never purged.** BIZEV-12 rules that retention belongs to
  the raw layer, that ledger rows hold only PII-minimal structure, and that an erasure is recorded as a tombstone. That
  is this ledger's position too, and a shred now records its tombstone. BIZEV-12's purge machinery (`purge_before`
  over a partitioned `SourceRecord`) does not apply here, because this ledger's raw layer is
  `AshEnterprise.Ingestion.SourceObject`, which a shred already reaches (ADR 0024). MDM's raw layer is the package's
  `SourceRecord` (ADR 0054), but it is not partitioned; adopting `purge_before` there is ADR 0054's call. No action
  deletes canonical rows other than by a shred. If one is ever added, it should record a tombstone in the same way.
- **Corrections cover a conversation's start only.** Message facts are once-only, and a calendar event's
  `occurred_at` is the write time (no provider time yet), so neither has an out-of-order truth to correct. A future
  consumer of the feed must treat a fact named by a later `supersedes_event_id` as replaced; no consumer exists yet.
- **Chains are per region, not per tenant.** A tenant cannot verify its own chain without the operator's
  `mix bizev.verify_chains`; the audit log's per-tenant chain (ADR 0002) is the comparison.

## Reversal

Remove the two `change {AshEnterprise.BusinessEvents.Changes.Derive, ...}` lines from `CalendarEvent` and `Message`,
and nothing records facts; the canonical store is untouched. Removing the domain entirely is `lib/ash_enterprise/
business_events*`, its config keys, the owner-only entry, the dependency, and an `ash.codegen` that drops the two
tables. No other resource references the ledger.

## Implementation note (2026-10-12)

- Upstream: BIZEV PR #3 (`e4c3c60`) — `record` passes `Ash.Context.to_opts/1` to the append and the delivery lookup,
  tolerates omitted optional arguments, and `ash_events` is a real dependency.
- Here: `AshEnterprise.BusinessEvents` (domain, `backfill/0`, config), `.Ledger`, `.Derivation`, `.Recorder`,
  `.Changes.Derive`, `.Changes.StampOwner`; migration `add_business_event_ledger`.
- Tests: `test/ash_enterprise/business_events/derivation_test.exs` (the mapping, pure),
  `.../ledger_test.exs` (one fact per change, as the owner; a failed record fails the write; backfill and its no-op;
  owner-only; a shred leaves the facts, a clean chain and no content), and the erasure end-to-end test now sweeps
  `business_events` for every synthetic content string before and after each vertical's shred, and verifies the chain.
- Dogfood: migrate, restart, then once inside the node `AshEnterprise.BusinessEvents.backfill()`; run
  `AshEnterprise.Platform.Seeder.seed_privileges()` and `regrant_administrator_privileges(org_id)` so the owner holds
  `:basic` read on the ledger. Set `BUSINESS_EVENTS_REGION` before the first fact if `local` is not the region.

## Implementation note (2026-10-18)

The package features the first three known gaps were waiting on have landed: BIZEV-9 (corrections, `b6d3c13`),
BIZEV-10 (simulation isolation, `542c513`) and BIZEV-12 (retention and erasure-as-event, `68886c4`).

- **Upstream: BIZEV PR #15 (`e5a54b6`).** BIZEV-10 still emitted the twin as a bare `use Ash.Resource`, so the host
  could not choose its base. The `:ledger` macro now takes `simulation_base: {module, use_opts}` and emits the twin as
  `use module, use_opts`. It refuses to compile when the base does not bring both ledger extensions.
  `simulation_runs/2` takes the read's options, so a multitenant twin can be listed. BIZEV-12's tombstones were
  recorded with no tenant and no context, which this ledger refuses. `purge_before/3` and `erase_subject/5` now take
  `record_opts:` and `context:`, and `Retention.tombstone/5` returns the tombstone's record input as data. The lock
  moved from `ce20e15` to `e5a54b6`; the usage-rules sync updated the ash-framework skill's reference.
- **The twin on the platform base.** `AshEnterprise.BusinessEvents.LedgerBase` is the one base both ledgers use:
  `AshEnterprise.Platform.Resource` (`:user_owned`, tenant-scoped, `audit?`/`archival?`/`lifecycle?` off) plus
  `StampOwner` on every append. The ledger uses it, and passes it as `simulation_base`. So `Ledger.SimulationEvent`
  has `organization_id` and the ownership columns, inherits the policy set, refuses an unowned row, and is owner-only
  (`Privilege.owner_only?/1`); the privilege sync picks it up as a platform resource. Migration
  `business_simulation_events_on_platform_base`: the columns are NOT NULL, which is safe because nothing has ever
  written the twin. Nothing writes simulated events yet.
- **Corrections (BIZEV-9).** `Derivation.message/3` takes the conversation's current start, which the recorder reads
  back with `by_subject`. If there is none, the message starts the conversation (same delivery key as before, so
  existing rows collapse). If the message was sent before the current start, it derives a new
  `conversation.started` whose `supersedes_event_id` names the start it corrects, keyed by that start, so deriving it
  twice records it once. Otherwise it derives no conversation fact. Nothing is rewritten. The package's
  `Ledger.Corrections` register is not used: it classifies by truth instant (same `occurred_at`, different data), and
  it seeds itself region-wide with raw SQL across tenants. A start moving earlier is a different shape, and
  `by_subject` already reads one subject in its tenant. The declaration gained `supersedes_when`, so
  `mapping_version_hash` changed for facts derived from now on. Read-decide-write now runs under the region's advisory
  lock (the same key `record` takes, `RegionLockKeyGenerator.key_for/1`), in a transaction. Without the lock, two
  messages of one conversation projected at once could both see no start, and the earlier one's start would collapse
  onto the later one's key.
- **Erasure-as-event (BIZEV-12).** `Scope.shred` now ends with `AshEnterprise.BusinessEvents.Changes.RecordShred`,
  after the key is destroyed and in the same transaction. Every owner whose facts point at the scope
  (`data.erasure_scope_id`) gets one `:"retention.subject_erased"` tombstone in their own tenant and stream, built by
  the package's `Retention.tombstone/5`. Its subject is the scope id, and its data is the scope id, kind, region and
  the count of the owner's facts it covers: never the scope's `ref` or `label`. It is idempotent per scope and owner.
  A scope nothing was derived from leaves none; its audited row is the record. A tombstone failure fails the shred,
  as a failed record fails a projection. `emit?: false` turns it off with the rest.
- **Gap 2** (`cross_region_read`) did not fall out of this work. It was decided on 2026-10-21: closed, pinned by tests, with the owner rule for a second region recorded (Known gaps).
- Tests: `test/ash_enterprise/business_events/derivation_test.exs` ("a conversation's start, corrected", "a shred's
  tombstone"); `.../ledger_test.exs` ("a later-arriving earlier message corrects the start; the first start stays",
  "a shred" with its tombstone and its idempotent re-record, "a scope nothing was derived from leaves no tombstone",
  "the simulation twin stands on the platform base", owner-only privileges for both ledgers). The erasure end-to-end
  test sweeps `business_simulation_events` too, and asserts one tombstone per vertical's shred, counting that
  vertical's facts, after them in the chain. Upstream: `test/simulation_host_base_test.exs` and `retention_test.exs`.
- Dogfood: migrate and restart, then run `AshEnterprise.Platform.Seeder.seed_privileges()` and
  `regrant_administrator_privileges(org_id)` (the twin is a new platform resource), and once
  `AshEnterprise.BusinessEvents.backfill()`. The backfill records a correcting start for any conversation whose start
  was recorded from a later message by live emission; it adds nothing else. Scopes shredded before this deploy have
  no tombstone. `AshEnterprise.BusinessEvents.Recorder.shredded/1` records one for a given shredded scope, if wanted.
