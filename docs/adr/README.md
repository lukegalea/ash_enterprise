# Architecture Decision Records

Each ADR records one fork in the road: what was decided, what the alternatives were, and — most importantly — **what
would have to change for the decision to be reversed**. That last section is what [thesis 6](../manifesto/06-reversibility.md)
demands, and it is the part worth writing carefully.

The manifesto in `../manifesto/` argues the position. These record the specific choices made while implementing it.

## Format

```markdown
# ADR NNNN — Title

- **Status:** proposed | accepted, not built (YYYY-MM-DD) | accepted | superseded by ADR-NNNN
- **Date:** YYYY-MM-DD

## Context
What forced a decision. Include the verified facts, with dates -- ecosystem
claims go stale fast and a reader in a year needs to know what was true when.

## Decision
What we chose, stated so someone can act on it.

## Consequences
What this makes easy, what it makes hard, what it forecloses.

## Reversal
The concrete exit: which files change, and how much work it is.
```

## Index

| ADR | Title | Status |
|---|---|---|
| [0001](0001-cdm-as-frozen-hybrid-corpus.md) | The CDM is a frozen, hybrid, vendored corpus | accepted |
| [0002](0002-ash-events-over-paper-trail.md) | AshEvents as the default audit layer, AshPaperTrail opt-in | accepted |
| [0003](0003-attribute-multitenancy.md) | Attribute-based multitenancy plus business-unit hierarchy | accepted |
| [0004](0004-reactor-over-oban-pro.md) | Reactor for transactional orchestration, Oban for durability | accepted |
| [0005](0005-admin-and-a2ui-division-of-labour.md) | ash_admin and ash_a2ui: division of labour | accepted |
| [0006](0006-design-system.md) | daisyUI 5 + Phoenix core_components as the design system | superseded by 0050 |
| [0007](0007-dialyzer-non-blocking.md) | Dialyzer runs, and does not gate | accepted |
| [0008](0008-typed-invertible-legacy-mappings.md) | Legacy mappings are typed expressions with proven inverses | accepted |
| [0009](0009-strangler-and-bpmn-are-first-party.md) | `ash_strangler`, `ash_bpmn` and `ash_decisions` are first-party platform extensions | accepted |
| [0010](0010-meltano-for-ingestion.md) | Meltano for ingestion, Airbyte as the named fallback | accepted, amended (2026-10-12; lands into an Ash resource, not a staging schema) |
| [0011](0011-nango-as-integration-hub.md) | Nango for the provider edge, sync logic stays in Ash | accepted (2026-10-12; Calendar, Gmail, Slack built) |
| [0012](0012-openlineage-and-marquez.md) | OpenLineage as the schema, Marquez as the backend | proposed |
| [0013](0013-openmetadata-as-catalog.md) | OpenMetadata as the catalog, populated from codegen | proposed |
| [0014](0014-superset-over-metabase.md) | Superset over Metabase for BI | proposed |
| [0015](0015-approvals-stay-in-ash.md) | Approvals and process modelling stay inside Ash | proposed |
| [0016](0016-unleash-for-feature-flags.md) | Feature flags: FunWithFlags, not Unleash | proposed |
| [0017](0017-entity-resolution-in-ash.md) | Entity resolution as Ash calculations over CDM resources | proposed |
| [0018](0018-grafana-lgtm-observability-backend.md) | Grafana LGTM as the observability backend | proposed |
| [0019](0019-api-versioning-as-presentation-contract.md) | API versioning is a presentation contract, not a schema fork | proposed |
| [0020](0020-tamper-evident-audit-log.md) | The audit log is tamper-evident, by two mechanisms | accepted |
| [0021](0021-control-mapping-is-generated.md) | The compliance control map is generated from the ledger | accepted |
| [0022](0022-audit-log-is-tenant-scoped.md) | The audit log is tenant-scoped by multitenancy, not a special check | accepted |
| [0023](0023-impersonation-is-attribution.md) | Impersonation adds attribution, never reach | accepted (in part) |
| [0024](0024-audit-retention-and-erasure.md) | Audit retention: partition for age, crypto-shred for erasure | accepted (2026-10-12; erasure built, partitioning not) |
| [0025](0025-log-shipping-and-review.md) | Logs ship to the customer's SIEM; review is evidence | proposed |
| [0026](0026-ai-governance-is-disclosure.md) | AI governance is disclosure, not a second authorization model | proposed (narrowed by 0042) |
| [0027](0027-feel-is-the-expression-language.md) | FEEL is the one expression language, and the engine is adopted rather than written | accepted |
| [0028](0028-decisions-are-dmn.md) | Decisions are DMN, measured against the TCK, in their own first-party package | accepted |
| [0029](0029-process-configuration-is-tenant-data.md) | Process and decision configuration is tenant data, defaulting to a platform baseline | accepted |
| [0030](0030-events-trigger-processes.md) | Events trigger processes through a dispatched cursor, not a handler | accepted |
| [0031](0031-the-legacy-estate-is-projected-not-cut-over.md) | The legacy estate is projected, not cut over | accepted |
| [0032](0032-anonymization-config-is-generated.md) | Anonymization config is generated from the resource declarations | proposed |
| [0033](0033-experience-layer-adoption.md) | The A2UI experience layer is adopted app-wide: experience v2 with the admin catalog | accepted |
| [0034](0034-canvas-dev-surface.md) | The canvas starts as a dev-only object graph with a naked-object inspector | accepted |
| [0035](0035-compliance-is-projected-from-events.md) | Compliance is projected from events under an immutable rule bundle | accepted |
| [0036](0036-converge-process-triggers-onto-projection-checkpoints.md) | Converge process triggers onto projection checkpoints | accepted |
| [0037](0037-projections-are-host-declared.md) | Projections are host-declared, from a vocabulary the library owns | accepted |
| [0038](0038-models-observe-declarations-decide.md) | Models observe; declarations decide | accepted (2026-09-28); the observe → band → admit path built (verified 2026-10-23) |
| [0039](0039-judgments-are-declared-questions.md) | Judgments are declared questions | accepted (2026-09-28); declared, locked questions built (verified 2026-10-23) |
| [0040](0040-record-dont-recompute.md) | Record, don't recompute | accepted (2026-09-28); the ledger and its replay-safe create built (verified 2026-10-23) |
| [0041](0041-thresholds-are-dmn-earned-by-calibration.md) | Thresholds are DMN, earned by calibration | accepted (2026-09-28); band tables earned by calibration built (verified 2026-10-23) |
| [0042](0042-in-zone-inference-leaving-the-zone-is-a-disclosure.md) | In-zone inference; leaving the zone is a disclosure | accepted; admission built for Gmail/Slack projection (2026-10-12), flow rule not built |
| [0043](0043-automation-authority-is-a-grant.md) | Automation authority is a grant | accepted (2026-09-28); the `ai` actor's bypass removed (built), the automation principal not built (verified 2026-10-23) |
| [0044](0044-documents-are-addressed-atoms-evidence-is-an-assertion.md) | Documents are addressed atoms; evidence is an assertion | accepted (2026-09-28); evidence assertions built (verified 2026-10-23) |
| [0045](0045-system-one-in-tooling-is-advisory.md) | System One in developer and agent tooling is advisory | accepted (2026-09-28); the host's advisory standards review built, the tooling package's model tier not built (verified 2026-10-23) |
| [0046](0046-the-declaration-is-the-output-contract.md) | The declaration is the output contract | accepted (2026-09-28); wire-schema contracts built for proposals, the one shared type-to-schema mapping not built (verified 2026-10-23) |
| [0047](0047-learning-produces-proposals.md) | Learning produces proposals | accepted (2026-09-28); person-confirmed proposal records built, offline learners not built (verified 2026-10-23) |
| [0048](0048-a-judgment-is-a-predicate-over-any-set.md) | A judgment is a predicate over any set | proposed |
| [0049](0049-temporal-resources-are-the-validity-substrate.md) | Temporal resources are the platform's validity substrate | accepted (2026-10-06; in progress) |
| [0050](0050-neobrutalism-design-system.md) | A neobrutalism token system, dark by default, replaces daisyUI | accepted |
| [0051](0051-business-events-are-derived-from-the-canonical-store.md) | Business events are derived from the canonical store, into a chained ledger | accepted |
| [0052](0052-self-service-actions.md) | Self-service actions: what a member may do for themselves without a grant | accepted |
| [0053](0053-subject-state-digest-third-axis.md) | The subject-state digest is the third axis: evidence currency, kept on the fact row | accepted (ruling 2026-10-09) |
| [0054](0054-mdm-stewardship-is-system-one.md) | MDM stewardship is System One machinery, not a bespoke product (amends 0017) | accepted |
| [0055](0055-consequential-acts-are-governed-invocations.md) | Every consequential act is one governed invocation | accepted, not built (2026-10-23) |
| [0056](0056-the-ash-agent-package.md) | The agent runtime is a separate public package, `ash_agent`, that the host instantiates | accepted, not built (2026-10-23) |
| [0057](0057-actions-declare-their-effects.md) | Every action exposed to an agent, an editor or a process declares its effects | accepted (2026-10-23); the extension, its verifiers and the host's ACP readers built, the library resolvers and ash_ai annotations not built (2026-10-29) |
| [0058](0058-agent-quality-and-releases.md) | Agent quality is measured in a host Quality domain, and a release is a gated, attested manifest | accepted, not built (2026-10-23) |
| [0059](0059-version-number-is-an-optimistic-lock.md) | `version_number` is an optimistic lock; human-only and machinery-only actions narrow the bypasses | accepted |

Records 0001–0005, 0007–0009, 0020–0023, 0027–0031, 0033–0037, 0050–0054 and 0059 are `accepted` and describe code that exists. 0006 is superseded by 0050. 0049 is accepted and in progress: Phase 0 (PostgreSQL 18) and the System One fact cut-over have landed.
**0038–0047 are `accepted, not built (2026-09-28)`:** the decision is taken and none of it is built. A record with that
status flips to plain `accepted` when its code lands, so `accepted` on its own keeps meaning code that exists.
**0012–0019, 0025, 0026, 0032 and 0048 are `proposed`: none of them is built**, with the exception 0015 below. 0010 (ingestion), 0011 (the Nango edge) and 0024 (crypto-shredding) were accepted on 2026-10-12 when the dogfood deployment began depending on them; each one's implementation note says what is built and where it differs from the Decision (0010 lands into an Ash resource rather than a staging schema; 0024's partitioning half is not built). They are here because a decision is cheapest to reason about — and cheapest to
*reverse* — while the alternatives are still fresh, and because
[thesis 6](../manifesto/06-reversibility.md) asks for the exit before the entrance. Three of them
record an answer that changed under verification, which is the main reason to write them down early.

0015 is the one deliberate straggler: its subject is built and demonstrated, and it stays `proposed`
because the specific negative test it named as its own acceptance criterion has not been written. A
record whose criterion is unmet does not get promoted for being nearly right.

Their sequencing, and the one rule they were all selected against, is [`../ROADMAP.md`](../ROADMAP.md).

0038–0047 are one set for probabilistic "System One" model judgments: 0038–0045 were written together on 2026-09-27
before any code, and on 2026-09-28 they were amended in place and 0046–0047 added. While unaccepted they were amended
rather than superseded, and each amended record says so under its date. A second pass the same day applied the
operator's answers — no hosted instrument, residency-checked admission into a zone, the activating person as author of
record, no novelty framing — and is marked "Amended 2026-09-28 (operator answers)" in each record it touched.
The operator accepted the set the same day ("reviewed doctrine and approve", 2026-09-28), and the acceptance pass
resolved four conflicts with earlier records: the automation principal never bypasses grants although system actors
do; the `ai` system actor loses its bypass; thesis 5's human decision moves to the moment a grant is made
([0043](0043-automation-authority-is-a-grant.md)); and 0042 narrows 0026, which both records now say. From acceptance
on, changing one of them takes an amendment marked as such or a superseding record.
0048 extends the set, and is `proposed`: it generalises the path from compliance to any consumer that selects records
(filters, search, segments, standing queries), following the operator's direction the same day that the mechanism
"applies to more than just compliance". It amends none of 0038–0047; it adds a consumer and the rules that consumer
needs (three-valued membership, no inference in reads, scores that order but never decide membership).
[Thesis 8](../manifesto/08-models-observe-declarations-decide.md) argues the position and
[`../plans/system-one.md`](../plans/system-one.md) sequences the work. They are not on the roadmap, and several of their
own decisions are marked pending inside them.

## On the four-section format

Six of the first eight records add sections beyond the prescribed four, and that is sanctioned rather
than tolerated: an ADR that needs a `## Why not X` or a `## Results` section is clearer for having one.
The four are a floor, not a ceiling.

Records 0009 onward add one further mandatory section, **`## Does it consume ActorContext?`**, placed
between Decision and Consequences. Every one of them concerns a tool or package outside the action
layer, and that question is the bar each had to clear — so it is answered in a fixed place, including
where the honest answer is "not yet, and here is what that costs".

## Writing a new one

Number sequentially, never renumber, never delete. A superseded ADR stays in place with its status updated and a pointer
forward — the reasoning that was wrong is often more useful later than the reasoning that was right.

## Correction, 2026-10-23: 0038–0047 are partly built

The paragraph above that says 0038–0047 are `accepted, not built (2026-09-28)` and that "none of it is built" was true
when it was written and is no longer. Each row in the index was checked against the source on 2026-10-23, and the rows
for 0038–0041 and 0043–0047 now say what is built. A row reads plain `accepted` only when all of its record is built,
so every one of these keeps a qualifier. The records' own status lines are left as they were written on 2026-09-28;
this index is where the current status lives.

| ADR | Built | Not built |
|---|---|---|
| 0038 | the path itself: observations in the judgment ledger (`SystemOne.Judgment`), banding against published band tables (`SystemOne.Banding`), admitted facts (`SystemOne.Fact`), person-only verdicts (`SystemOne.HumanVerdict`) | — beyond what the records below list |
| 0039 | questions declared on `Canonical.Task` and `Licences.Dependency`, locked in `priv/judgments/lock.json` | — |
| 0040 | the append-only ledger whose create accepts the answer as input, with cache key, record hash and erasure tombstone (`SystemOne.Judgment`) | the erasure-versus-replay question the record marks pending is still open |
| 0041 | band tables as `ash_decisions` definitions, published only after a person's certification and a compliant calibration run (`SystemOne.BandTablePublication`, `CalibrationRun`, `BandTableCertification`) | — |
| 0043 | the `ai` system actor's bypass is removed and it resolves to an empty context (`Security.Checks.SystemActor`, `Security.ActorContext`) | the automation principal and its grants |
| 0044 | evidence adjudication over `ash_evidence` documents, recorded as assertions (`SystemOne.Evidence`, `SystemOne.EvidenceAssertion`) | — |
| 0045 | the advisory standards review over this repository's own code, which never fails a build (`AshEnterprise.Standards`) | the `:model` tier and explicit promotion thresholds in the agent tooling package |
| 0046 | decode-time wire schemas, validated after decode, for question proposals (a static schema with no confidence field, `SystemOne.QuestionProposal.Schema`) and filter proposals (derived per call from the declared queryables, `SystemOne.Filter.Schema`) | the one generated type-to-JSON-Schema mapping shared by every consumer |
| 0047 | proposal records that only a person adopts: question proposals, filter proposals and action-item proposals (`SystemOne.QuestionProposal`, `SystemOne.FilterProposal`, `Canonical.Commitments`) | optimisers, distillation and other offline learners |

0055–0058 record the agent runtime decided on 2026-10-22 and 2026-10-23: one governed invocation for every
consequential act, the runtime as a separate package the host instantiates, a per-action effects declaration, and
agent evaluation with gated releases. None of it is built yet. 0055 and 0056 carry amendments of 2026-10-29: the coding-agent
bridge's approval half moves onto the invocation while its sessions stay separate, ash_ai and req_llm are upgraded
wherever needed, and the package's dependency tree allows one Phoenix edge (ash_ai -> ash_json_api -> phoenix).
