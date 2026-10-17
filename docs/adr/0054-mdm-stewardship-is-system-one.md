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
- **The queue is filtered by the golden** (item 1 of "Does it consume ActorContext?", restated from 0017): `:review_queue`
  lists a candidate only when the reader may read its golden, through an unrelated `exists` on Person that Ash
  authorizes with Person's read policy (`exists(golden, ...)` through the relationship joins past it). Since Person is
  owner-only, most stewards see the candidates for goldens they own. Confirm match is refused, as `Forbidden`, for a
  golden the actor may not read, even when opened by id, and `ReviewQueue`'s `:mdm_match` reads the same action.
  `NextEvent` and `LatestMessage`, the remaining calculations that named a relationship in `load/3`, now load it as the
  reader in the same way.
- **Bulk** is reject only. A merge is a person's decision about one pair; rejecting a page of weak matches keeps every
  staged row a record of its own and can be redone by an import.

The golden-records, mapping and import-batch surfaces gained details (related source identities and merge history; a
mapping's rules and predecessor; a batch's counts, failure and staged rows), each read under its own resource's
policies. Mapping activation stays off surfaces. ImportLive now drafts and validates a mapping as the person, as it
already activated one.

## Addendum, 2026-10-17 — the task decides the candidate, and a Data Steward role

**Labels, not wrappers.** `ash_a2ui` now labels a button from its `action` entity (`label`), so `:confirm_match`,
`:reject_match` and `:mark_unsure` and the `StewardDecision` module behind them are deleted. The queue's buttons are
`:confirm`, `:reject` and `:escalate` themselves, labelled Confirm match, Reject match and Mark unsure, and bulk is
`:reject`. The rule that nobody confirms a merge into a golden they cannot read moved onto `:confirm` as a validation
(`AshEnterprise.Mdm.Validations.GoldenReadable`, `Forbidden`), so it holds for every caller, not only the surface.

**One decision, wherever it is made.** Completing the steward-decision task used to complete the task alone: the
candidate stayed pending while its process ended, and Approvals' Approve completed it as `approved`, which the diagram
does not declare, so the gateway's default sent it down the reject branch. Now a steward-decision task is decided by
recording the verdict on its match candidate as the person (`AshEnterprise.Mdm.StewardTask`): `confirm` / `approved`
→ `:confirm`, `reject` / `rejected` → `:reject`, `escalate` → `:escalate`. The verdict's `after_action` completes the
task through the engine as the person, in the same transaction, for a claimed task as well as an open one; if the
engine refuses (they are not a candidate, or someone else holds it), the verdict is refused and nothing is written.
That applies to the queue too: while a candidate has a live steward-decision task, only someone who may decide that
task may decide the candidate. Escalating records the steward as unsure and completes nothing; the task stays with
them to delegate to a senior steward. The diagram declares `escalate` so the board offers it, and adds Data Stewards
as candidates.

Every completion path also refuses an outcome the task's step does not declare (`AshEnterprise.Bpmn.Outcomes`, reading
`HumanTask.declared_outcomes` through the configured definition loader: the engine's own `:outcomes` reads the
definition in the task's tenant and answers `nil` for a platform baseline such as this one), and
the task board's Complete prompt offers a picker. Its options are fixed when the resource compiles (every outcome a
checked-in baseline declares), because a prompt's ChoicePicker takes literal options; per-card options need
per-record prompt options in `ash_a2ui`.

**A Data Steward role.** Every tenant is seeded with a Data Steward role holding the steward-queue grants (read and
write on match candidates; read on staged records, import batches, mappings and source identities; `:basic` read on
Person; create on the human verdict a decision records) and the MDM egress grant (`prvReadEgress`), each at the widest
depth its privilege allows (`Seeder.ensure_data_steward_role/2`). It holds no task grant: stewards read and act on
their tasks through candidacy (ADR 0009, note of 2026-10-17). Existing tenants receive it through
`mix ash_enterprise.platform.grant_data_steward` (dry run unless `--apply`; additive and idempotent; assigns the role
to nobody), not at boot, because adding a role to a customer's tenant is a deliberate act.

## Addendum, 2026-10-17 — projected people are an MDM source (PROD-9)

**Context.** The Gmail, Calendar and Slack projectors key `Canonical.Person` on the email address, so one human with a
work address in Slack and another in Gmail is two rows. MDM's only input path was the CSV upload.

**Decision.** The projected people are a second bizev source on the same landing (`:canonical` / `:people` in
`AshEnterprise.Mdm.Landing`, adapter `AshEnterprise.Mdm.People.Adapter`): one observation per person per source system
and linked account, staged through an ordinary `ImportBatch` against an ingress mapping (`canonical`/`people`) and
scored by a match rule set, both seeded as data and activated by a person (`AshEnterprise.Mdm.People.Seed`). A sweep
(`AshEnterprise.Mdm.People.SweepWorker`, `:mdm` queue; `mix ash_enterprise.mdm.people`) runs it per tenant. What
differs from a CSV row, and why:

- **An observation is already a person.** Its own row is a candidate like any other, so "same address → admit" is the
  rule set and the band table deciding, not a special case; the admit opens the observation's identity at that row.
- **Only one owner's people are paired.** Person is owner-only; a merge across owners would hand one user's
  correspondence joins to a row another user owns. Each pair is asked once, from the newer person to the older, which
  survives; a pair with a standing answer (pending, confirmed, rejected, auto-merged) is not asked again, so an unmerge
  is not undone by the next sweep.
- **Admit or confirm merges the person** (`:mdm_merge_into`), not the staged row. The merge now also moves the rows
  that name the absorbed person — attendee and participant joins, `Message.sender`, `CalendarEvent.organizer`, and
  records it absorbed earlier — and records their ids on `merge_provenance` so the unmerge moves exactly those back
  (`AshEnterprise.Mdm.PersonJoins`). A survivor that is itself merged is refused, so a master is always a golden.
- **The absorbed row keeps its address** unless the survivor takes it, and the projectors link a merged row's address
  to its golden (`AshEnterprise.Canonical.Projections.Golden`, same owner only). Otherwise the next projection would
  mint the duplicate again. Rows projected after a merge name the golden; after an unmerge, the next projection of
  their source re-derives them.
- **The rule set has its own key**, `"AshEnterprise.Canonical.Person#people"`: `ash_mdm` keeps one active rule set per
  `golden_resource`, and activating the people rules must not retire the CSV import's. The package-level fix is a scope
  on the rule set.
- **Shared context is a host-computed pair feature.** The package's comparators are `exact` and `fuzzy` over fields;
  "these two are in the same meetings or threads, or meet the same people" is a fact about the pair, with no operator
  for it. The matcher computes it and an `exact` rule compares it; the package-level fix is an `overlap` comparator over
  list fields. Weights are chosen so nothing reaches the seed table's admit band without the address.

Nothing here adds a schema change. The steward queue, the System One review queue, the person gate and the band table
are the import's, unchanged.
