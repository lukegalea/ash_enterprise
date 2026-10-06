# 9. ADR 0049: Temporal resources are the platform's validity substrate

- Status: **Accepted** (Luke, 2026-10-06 — "GO ALL IN")
- Supersedes: the pilot-gated posture drafted in `system-one-program/research/temporal-resources-strategy.md` (see its 2026-10-06 addendum)
- Context: [Introducing Temporal Resources](https://ash-hq.org/blog/introducing-temporal-resources); [temporal resources guide](https://hexdocs.pm/ash/temporal-resources.html); deep dive + inventory in the programme repo.

## Decision

Adopt Ash temporal resources as the standard mechanism for validity, versioning, and
effective-dated state across the platform and its packages — now, not behind a stability gate.
Where the family today hand-rolls period bookkeeping (`valid_until`/`superseded_by` chains,
in-force-now filters, revision pinning, upsert-in-place config), new work temporalizes and
existing machinery migrates by value-ranked order.

## Rationale

The platform is greenfield: no legacy data gravity at scale, a single maintainer, and every
consumer of these packages is us. The feature's youth (experimental, released 2026-10-03) is
repriced as an opportunity — we expect to hit sharp edges early and contribute fixes upstream
(issues/PRs to ash/ash_postgres) as first-class programme work, not as risk to avoid.

## What the ruling does not change (invariants)

1. **PostgreSQL 18 + `btree_gist` is the prerequisite.** Dev environments first; the zone
   database is never upgraded for convenience — only at a coordinated zone-review moment.
2. **Frozen contracts stay frozen.** RFC v1's §7.4 semantics migrate only as a v2 evolution:
   normatives survive verbatim and the behavioral equivalence tests
   (`Set.membership ↔ Query.tri_state`, materialiser replay-equivalence) pass unchanged.
   The contract is behavioral, not structural — that is what makes a mechanism swap a v2.
3. **The zone record stays config-not-DB** (VPM-25, attested 2026-10-05). A shadow temporal
   mirror is the only compatible enhancement; the attestation model is not traded for queries.
4. **Temporal-safety is an audited property**, not an assumption: every custom
   change/validation/preparation on a temporal resource is module-refactored and
   `temporal_safe?/1`-declared, or removed. The cost of this audit prices the migration pace.
5. **`AshPostgres.Temporal.WriteConflict`** has a written app policy (surface, envelope-only
   logging, no auto-retry storm), and raw SQL writes to temporal tables are banned (they bypass
   the split-write locking protocol).
6. **ash_events remains the tamper-evidence spine.** Temporal rows carry validity; the
   hash-chained log carries what-happened. Their interplay (replay rebuilding identical
   periods) is verified early (S1-67) and gates the deepest migrations.
7. **Actor-as-of discipline**: no as-of writes on policy-sensitive surfaces until upstream
   ships transparent actor reloading; backdating is config-import-only for now.

## Consequences

- Date↔period boundary convention is pinned once (inclusive legacy `DATE` → half-open datetime:
  `activeFrom` → `T00:00:00Z`, `expiry` → exclusive `+1 day`) and reused by every migration.
- The five pilot demonstrations (as-of reads, future-dated writes, WriteConflict behavior,
  temporal-safety audit cost, ash_events replay) run as the opener of VPM-49 — engineering
  verification, not a go/no-go gate.
- Emergent capabilities become roadmap items: expiry-as-a-queryable-dimension (VPM-50) leads;
  as-of joins retire pre-computed digest plumbing where they genuinely can (see strategy
  correction #1 — `subject_state_digest` is NOT among them).
- Exit cost stays small per resource (~4 DSL lines + one migration to revert) but the platform
  is now committed to the direction.
