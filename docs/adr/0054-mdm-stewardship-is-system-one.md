# ADR 0054 — MDM stewardship is System One machinery, not a bespoke product

- **Status:** accepted
- **Date:** 2026-10-14
- **Amends:** [ADR 0017](0017-entity-resolution-in-ash.md)

## Context

ADR 0017 decided entity resolution in Ash over CDM-shaped golden records, and it
was right about the mechanics: blocking in Postgres, scoring as a calculation,
merge as an ordinary action, `merged`/`master_id` adopted from the corpus rather
than invented. But it carried one clause that has aged: *"Foreclosed. A
vendor-supported data-steward experience. There is no review queue, no rule
builder, no lineage-of-merges UI, and building them is not on the path this ADR
chooses."*

That clause was a judgement about cost, not about principle. When 0017 was
written (2026-08-18) a stewardship UI would have been a bespoke product — the
exact trigger 0017 named for reaching for an external MDM hub. The substrate it
would have had to be bespoke against did not exist yet. It exists now, as
first-party machinery:

- **ReviewQueue** — `SystemOne.ReviewQueue.pending/1` already fans four kinds
  of work items; a fifth kind is additive, not a new product.
- **HumanVerdict** — person-only confirmation (no system or AI actor can forge
  a decision) that already feeds live calibration. This *is* the "human
  confirms the low-confidence match" primitive.
- **BPMN HumanTask** — claim/assignment model (`open→claimed→completed`),
  `TaskCandidate` rows from `AssignmentResolver`, maker-checker exclusions,
  and the `TaskListLive` surface. Queue mechanics are the process engine's.
- **Band tables as versioned DMN** — thresholds earned by calibration
  (ADR 0041), never literals in code; `:review` writes nothing, absence is
  unknown.
- **A2UI declared surfaces** — drill-down record views (`FindingUI` precedent)
  rendered from declarations.
- **`ash_discrete_business_events`** — temporal raw landing with zone
  admission at land (ADR 0042), and a hash-chained ledger with provenance.

## Decision

**Build the full MDM flow — ingress mappings as data, matching, stewardship,
merge, egress, lineage — on the existing substrate, as the `ash_mdm` package
plus a thin `AshEnterprise.Mdm` host domain. ADR 0017's mechanics stand
verbatim; its Foreclosed clause is amended.**

Kept from 0017 without change:

1. In-Ash resolution. The golden record **is** the platform resource carrying
   CDM's `merged`/`master_id` shape; there is no hub.
2. Blocking pushed into Postgres: `pg_trgm` for the trigram shortlist,
   `fuzzystrmatch` for the Levenshtein/metaphone comparators. Both are now in
   `AshEnterprise.Repo.installed_extensions/0` — the "first concrete cost"
   0017 predicted, paid on adoption.
3. Scoring as an Ash calculation, pushed to SQL where the comparators are SQL
   functions, BEAM fallback otherwise.
4. Candidate generation runs as a system actor; the presentation layer is
   filtered separately, so a review surface never discloses the existence of a
   candidate the viewer cannot read.
5. Merge is audited under one correlation id — the survivor update, every
   loser update, the SourceIdentity repointing and the ledger event share the
   import batch's id, which is the only thing that makes "why did this
   disappear" answerable after a grant silently stops matching.
6. Splink remains the escape hatch: an offline scoring job writing a candidate
   table localises the statistics without touching blocking, merge or
   stewardship.

Amended: the review queue, the rule builder (as **mappings-as-data** — a
versioned, validated field-rule DSL, not a UI that emits code), and the
lineage-of-merges view are built **on** ReviewQueue, HumanVerdict, BPMN, A2UI
and band tables. None of them is bespoke; each is a new *kind* of an existing
surface. The non-deploy property falls out of the same choice: onboarding a new
customer schema is authoring `Mapping` rows (validated, versioned,
person-activated), never a release. Deploy remains required only for a new
system *adapter* (code), a new canonical *entity* (migration), or a new
judgment *question wording* (questions are contracts, pinned in
`priv/judgments/lock.json` by design).

## Does it consume ActorContext?

Yes — structurally as before, since every golden record is a platform
resource, and in the same two sharp ways 0017 named, plus three new edges the
stewardship flow adds:

1. **System-actor candidate generation + filtered presentation.** Restated
   from 0017: matching must see across business units, so the review surface
   intersects candidate `golden_id`s with the viewer's readable set and shows
   the filtered count, never the raw count.
2. **Merge revokes access without revoking a grant.** Restated from 0017:
   shares are keyed on record ids that merge away. Every merge (and its
   correction, the unmerge) is audited under the batch's correlation id.
3. **HumanVerdict refuses non-person actors.** A steward confirmation is a
   person's judgement; the package's merge path consumes verdicts and the
   host's `Checks.PersonActor` policy guarantees provenance. Negative-tested.
4. **Mapping activation is person-gated.** System actors may *propose*
   mappings (the AI-proposal path); only a person activates, and activation
   supersedes rather than overwrites — the QuestionProposal version-chain
   pattern applied to schemas.
5. **Egress honours zone admission.** Admission is taken at land (ADR 0042);
   the export action adds the disclosure gate: cross-region export is refused
   unless the tenant's zone policy admits it.

## Consequences

**Made easy.** The flagship flow — CS uploads a customer file, maps it in the
UI, the system matches, the human confirms the gray zone, the golden record
emerges with full lineage — is assembled from parts that already exist and are
already tested. Steward confirmations are calibration samples, so the band
tables tighten from data, not releases.

**Made hard.** The no-deploy guarantee is only as strong as the operator
vocabulary of the mapping DSL is *closed*. Adding an operator is a package
change with a validator and tests; there is no eval, no quoted Elixir, and the
validator refuses an unexplained unmapped target attribute. The escape hatch
stays where 0017 put it, and the honest cost statement stands too: a
hand-built deterministic+fuzzy score is fine for email-exact and trigram-shortlist
work, and the wide-review seed (more human confirmations, fewer wrong merges)
is the safe direction while calibration data is thin.

## Addendum, 2026-10-16 — egress is its own grant

*Decided by the owner, 2026-10-16: "Separate egress grant — Move the export to an MDM-owned action with its own
grantable privilege, held by stewards and checked from ActorContext. That privilege authorizes reading this tenant's
golden persons for egress. The zone disclosure gate still applies. Person stays owner-only for everything else,
including mail."*

**What changed underneath.** Item 5 above put the export on the golden resource, as `Person.mdm_export`, authorized by
`RoleGrant`. Since then `AshEnterprise.Canonical.Person` became owner-only (`Privilege.owner_only?/1`, ADR 0042's
"owner-only reads"): grantable at `:basic` and no wider, and skipped by hierarchy security, because the same table holds
one person's mail and Slack correspondents. `RoleGrant` authorizes a generic action only on a `:global` grant — a
generic action has no row for a narrower depth to reach — and nobody can hold `:global` on Person any more. The export
was authorized for no one.

**Decision.** The departure moves to `AshEnterprise.Mdm.Egress.export/2`, a generic action on an MDM-owned resource
with no rows. Its privilege, `read` on `AshEnterprise.Mdm.Egress` (`prvReadEgress`), is derived into the catalogue like
every other, is grantable at `:global` only, and is held by whoever the tenant makes a steward (today the Administrator,
through the ordinary auto-grant; the demo Auditor is deliberately not given it). The policy is the inherited grant union,
unchanged: `RoleGrant` answers from the precomputed `ActorContext`, no check queries, and there is no `forbid_if`.

Passing that policy authorizes one read inside the run, made with `authorize?: false` and fixed in code
(`AshEnterprise.Mdm.Export`):

- **the actor's own tenant** — a grant is a row in the tenant that holds it, and the resource is untenanted, so the run
  refuses any tenant but the one the actor's context was built in;
- **golden persons only** — Person's `:goldens` read (some SourceIdentity points at it, no merge absorbed it);
- **the fields the active egress mapping names** — public Person attributes only, selected; a rule naming anything else
  refuses the export.

The zone disclosure gate is unchanged and still runs on every golden, on the residency recorded at land.

**Why this is not a second security model.** Egress is one more `(resource, verb)` row in the same catalogue, granted
and revoked the way every other privilege is, and visible in the same admin UI; the only thing written in code is what
the grant reaches, which is the same kind of statement a depth makes for a read. It does not grant Person: a steward
holding only the egress grant reads no Person row, and the action returns mapping-shaped rows, never records. The tenant
refusal is tenant isolation — the property multitenancy gives every tenanted read — not a deny rule in the union.

**Rejected.** Widening Person (an egress-only depth, or an exception in `owner_only?/1`) would reopen exactly the path
owner-only closed: a role that reaches every person row is a role that reaches every mail correspondent. A
system-actor export would remove the grant altogether and leave "who may export" unanswerable from data.

**Costs.** An export no longer requires the exporter to be able to read the rows it exports; that is the point, and it
is why the reach is narrow and the gate stays. The export is not yet written to the audit trail as a disclosure event of
its own.

## Addendum, 2026-10-16 — the steward queue is an A2UI surface

**Context.** `StewardLive` was a hand-built queue that read the staged row and the golden behind each candidate with
`authorize?: false`, so a steward saw values the grant union might hide — the second security model this record says
the queue does not have. It also queried in `mount`.

**Decision.** The queue is `AshEnterpriseWeb.A2ui.MdmStewardUI` over `MatchCandidate`'s `:review_queue` read
(review band, pending, oldest first), at the same `/app/mdm`. `StewardLive` is deleted. Its pieces map as follows:

- **The diff** is calculations on `MatchCandidate` (`staged_name`, `golden_name`, `name_survivor`, …). They load
  `staged_record` and `golden` with `Ash.load/3` as the reader
  (`AshEnterprise.Platform.Calculations.RelatedField`), so a staged row or a golden the reader may not read leaves its
  side empty, and no survivorship is claimed for a golden they cannot see. Two shorter forms were tried first and both
  leaked an owner-only name to a steward holding no Person grant: an expression through the relationship
  (`expr(golden.name)`, whose join skips Person's read policy) and a module calculation naming the relationship in
  `load/3` (Ash loads calculation dependencies without authorization). The second form was also how
  `AshEnterprise.Canonical.Calculations.PersonLabel` named a message's sender and an event's organizer; it now loads
  the same way. The test that caught it stays (`test/ash_enterprise_web/a2ui/mdm_steward_ui_test.exs`).
- **The buttons** are `:confirm_match`, `:reject_match` and `:mark_unsure`, generic actions that exist for their labels
  (ash_a2ui labels a button by its action's name). Each runs `:confirm`, `:reject` or `:escalate` **as the actor**, so
  the person gate and the update grant decide exactly as before, and the verdict recorded is still the update's name.
  They are self-service (ADR 0052) because they authorize nothing themselves: being able to run one grants nothing that
  the update does not. Each is shown only while the candidate is pending (`visible_when`), and the handler re-checks
  that on every click.
- **Bulk** is reject only. A merge is a person's decision about one pair; rejecting a page of weak matches keeps every
  staged row a record of its own and can be redone by an import.

The golden-records, mapping and import-batch surfaces gained details (related source identities and merge history; a
mapping's rules and predecessor; a batch's counts, failure and staged rows), each read under its own resource's
policies. Mapping activation stays off surfaces. ImportLive now drafts and validates a mapping as the person, as it
already activated one.
