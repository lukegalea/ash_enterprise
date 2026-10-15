# ADR 0053 — MDM stewardship is System One machinery, not a bespoke product

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
