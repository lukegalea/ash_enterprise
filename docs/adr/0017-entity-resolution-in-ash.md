# ADR 0017 — Entity resolution is Ash calculations over CDM resources, not a separate MDM system

- **Status:** proposed
- **Date:** 2026-08-18

## Context

Ingestion ([ADR 0010](0010-meltano-for-ingestion.md)) makes duplicates inevitable. The moment the same customer
arrives from a CRM export and a billing extract, or the same vendor from two acquired subsidiaries,
something has to decide that two rows are one company and which of the conflicting values survives.
That is entity resolution, and the enterprise answer to it is usually a master data management hub — a
separate product that owns the golden record.

Two self-hostable candidates were examined, and the licence facts on both have moved recently. Verified
2026-08-18 against `LICENSE` files and vendor announcements, not from memory:

- **AtroCore** is **GPL-3.0**, not MIT. `LICENSE.txt` on master is GPLv3 and the README says so; the
  vendor's own comparison blog claims MIT, which contradicts their repository — trust the file. PHP
  8.4–8.5 on Symfony, PostgreSQL recommended. Latest 2.3.16-beta6 (2026-08-18); actively developed. It
  genuinely has the feature that would justify it: a matching framework with UI-configured Matching
  Rules, cluster creation, a Golden Record field and a data-steward workspace, introduced in v2.2.0
  (2025-11-17) and extended through v2.3.0. Whether matching is in the free core or in AtroCore's
  Premium Modules is **unverified**.
- **Pimcore is no longer open source.** It relicensed from GPLv3 to the **Pimcore Open Core License**,
  source-available, with 2024.4 the last GPLv3 release and 2025.1 the first POCL one. POCL imposes a
  **€5M annual revenue ceiling** on free production use, forbids offering the software as a hosted
  service, and forbids forking it into a functionally comparable product. For most enterprise buyers
  Pimcore is now a paid product, and it fails this repository's open-source-only requirement outright.
- Of the dedicated engines: **Senzing** is proprietary with no free production tier (list pricing
  ~$58,560/year at 10M records). **Zingg** is AGPL-3.0, Java/Spark, actively maintained (v0.7.0,
  2026-08-10). **Splink** is **MIT**, Python, actively maintained (v4.0.16, 2026-03-11), implements
  Fellegi-Sunter with EM training and pushes work down to SQL backends. Splink is the one worth naming.

Meanwhile the CDM corpus this application is built on
([thesis 2](../manifesto/02-schema-commons.md)) already models the answer. Grepping the vendored
`priv/cdm/schemaDocuments/core/applicationCommon/Account.cdm.json` on 2026-08-18 finds a nullable
boolean `merged` — *"Shows whether the account has been merged with another account"* — and a
self-referencing `master` relationship whose foreign key `masterid` carries the description *"Shows the
master account that the account was merged with."* The same attributes are present on `Contact`.

So the golden-record model does not need inventing, and per thesis 2 it should not be: it is already in
the corpus, and it is a survivor pointer plus a flag rather than a separate hub.

## Decision

**Do entity resolution in Ash, over CDM-derived resources, using the corpus's own `master`/`merged`
shape. Reach for an external MDM hub only on a stated trigger.**

The pipeline is ordinary Ash, in three stages:

**Blocking** — candidate generation, as a read action. This is the stage that must be pushed into
PostgreSQL, because comparing every row to every row is quadratic and comparing every row to a trigram-
indexed shortlist is not. `pg_trgm` supplies `similarity()`, the `%` operator and GIN/GiST index support
and is a trusted contrib module; `fuzzystrmatch` supplies `levenshtein`, `daitch_mokotoff` and the
metaphone family. **Neither is in `AshEnterprise.Repo.installed_extensions/0` today** — adding them is a
one-line change and a migration, and it is the first concrete cost of this decision.

**Scoring** — an Ash calculation over a candidate pair. Expression calculations push to SQL where the
comparators are SQL functions, and fall back to the BEAM where they are not.

**Merge and survivorship** — an Ash action. The surviving record is an ordinary
`AshEnterprise.Platform.Resource`; the losers get `merged: true` and `master_id` pointing at it.

The reason to prefer this over a hub is the same reason
[thesis 4](../manifesto/04-batteries-are-inherited.md) gives for the base resource. A golden record that
is an Ash resource inherits ownership, provenance, lifecycle, tenancy, soft delete, the policy set and
the `AshEvents` audit trail because it inherits them — not because someone remembered. A golden record
inside an MDM hub inherits that hub's access model, and there is then a second answer to "who can see
this customer" which nobody can reconcile with the first.

**The trigger for reaching for AtroCore instead**, stated so it is a decision rather than a drift:

1. The golden record must be **decoupled from this application** — consumed by systems that do not and
   will not talk to it, so the hub is the integration point rather than a subsystem; or
2. **Non-developers must author matching rules through a UI.** AtroCore's Matching Rules and data-steward
   workspace exist for exactly this, and building an equivalent here is a product, not a feature.

Neither trigger is "the matching is hard." Hard matching is an argument for Splink, not for a hub.

## Does it consume ActorContext?

Yes, structurally — the golden record is an Ash resource on the platform base, so every policy path in
[thesis 3](../manifesto/03-authorization-is-data.md) applies to it with no integration work. That is the
whole argument for this decision. But it consumes it in two ways that need stating, because both are
sharp.

**Candidate generation must run as a system actor.** Duplicates do not respect business units — the
point of resolution is that two units each created a record for one company. A read scoped by the
merging user's `ActorContext` would find only the duplicates they can already see, which is the ones
least likely to matter. So the blocking stage runs under `ActorContext.system/1`, and that means the
merge surface must not disclose the *existence* of a candidate the actor may not read. A review queue
that shows "3 possible duplicates" to someone entitled to see one of them is a leak, and it is one this
pipeline creates by design unless the presentation layer is filtered separately from the matching.

**A merge can revoke access without revoking a grant.** Every grant path in `ActorContext` is per
record: `RoleGrant` tests the record's `owning_business_unit_id` against a precomputed id set, and
`SharedWithActor` tests the record id against a precomputed share set. Merging two accounts owned by
different business units produces one survivor with one owning business unit — so a user in the losing
unit stops seeing the customer, with no role changed and nothing in the security tables to explain it.
The union of grants stays pure; the *records* moved underneath it. Shares are worse, because they are
keyed on a record id that is now merged and the share does not follow.

Neither is a reason not to do this. Both are reasons the merge action must be audited with a correlation
id — `AshEnterprise.Platform.Correlation` groups the survivor update and every loser update into one
operation, which is the only thing that makes "why did this disappear" answerable afterwards.

## Consequences

**Made easy.** The golden record is queryable, policy-enforced, tenanted and audited with no
integration. Survivorship rules are changes and calculations, so they are unit-testable against
fixtures rather than clicked. The CDM's `master`/`merged` shape means merge is non-destructive by
construction: the losing rows survive, pointing at the survivor, which is what makes an unmerge possible
at all.

**Made hard, and this is the real cost.** *There is no probabilistic record-linkage library in Elixir.*
Verified 2026-08-18 by searching hex.pm for record linkage, entity resolution, deduplication and every
adjacent term: every hit is a **string-distance metric**, not a linkage engine. `fuzzy_compare` 1.1.0
(2024-12-25), `the_fuzz` 0.6.0 (2025-07-24), `akin` 0.2.0 (2023-09-03), `ex_fuzzywuzzy` 0.3.0
(2024-01-04), plus `String.jaro_distance/2` and `String.bag_distance/2` in the standard library. Nothing
implements Fellegi–Sunter, EM-trained match weights, threshold calibration, transitive clustering or
survivorship.

So this decision buys the *plumbing* — blocking, storage, policy, audit, review — and leaves the
*statistics* hand-built. A hand-built score is a set of weights someone chose, and it will be wrong in a
way nobody can quantify, because there is no trained model to report a false-match rate from. Budget for
that honestly: it is fine for "same email domain and Levenshtein under 3", and it is not fine for
merging customer records at a scale where the error rate is a compliance question.

**The escape hatch, if it becomes one.** Splink is MIT and executes against SQL backends, so it can
score offline against the same PostgreSQL and write match scores back into a candidate table that Ash
reads as an ordinary resource. That keeps the golden record, the policies and the audit trail here and
puts only the statistics elsewhere. It also adds Python to the deployment, which is why it is an escape
hatch and not the decision.

**Foreclosed.** A vendor-supported data-steward experience. There is no review queue, no rule builder,
no lineage-of-merges UI, and building them is not on the path this ADR chooses.

## Reversal

Nothing is built: no matching resources, no `pg_trgm` or `fuzzystrmatch` in
`AshEnterprise.Repo.installed_extensions/0`, and the CDM `master`/`merged` attributes are in the corpus
but not yet on any generated resource.

**To adopt AtroCore instead:** stand up a PHP/Symfony application with its own PostgreSQL, define the
golden record there, and either replicate it back or treat this application as a spoke. The work is not
the deployment; it is that the hub's access model must be reconciled with `ActorContext` forever after,
and there is no mechanism proposed here for doing that. Note the licence: GPL-3.0, and whether the
matching framework is core or Premium is unverified — check before committing.

**To move scoring to Splink while keeping everything else:** add a Python job writing to a
`match_candidate` table and replace the scoring calculation with a read of it. Localised — the blocking
stage and the merge action are unaffected — and it is the reversal most likely to be needed.

**To abandon in-Ash resolution after adoption:** the exposure is the matching resources, the merge
action and two PostgreSQL extensions. The `master`/`merged` attributes stay, because they are CDM
columns rather than tooling, so the *data* survives whatever resolves it. That is the seam
[thesis 6](../manifesto/06-reversibility.md) asks for, and it exists because the corpus supplied the
shape rather than the tool supplying it.
