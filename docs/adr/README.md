# Architecture Decision Records

Each ADR records one fork in the road: what was decided, what the alternatives were, and — most importantly — **what
would have to change for the decision to be reversed**. That last section is what [thesis 6](../manifesto/06-reversibility.md)
demands, and it is the part worth writing carefully.

The manifesto in `../manifesto/` argues the position. These record the specific choices made while implementing it.

## Format

```markdown
# ADR NNNN — Title

- **Status:** proposed | accepted | superseded by ADR-NNNN
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
| [0006](0006-design-system.md) | daisyUI 5 + Phoenix core_components as the design system | accepted |
| [0007](0007-dialyzer-non-blocking.md) | Dialyzer runs, and does not gate | accepted |
| [0008](0008-typed-invertible-legacy-mappings.md) | Legacy mappings are typed expressions with proven inverses | accepted |
| [0009](0009-strangler-and-bpmn-are-first-party.md) | `ash_strangler`, `ash_bpmn` and `ash_decisions` are first-party platform extensions | accepted |
| [0010](0010-meltano-for-ingestion.md) | Meltano for ingestion, Airbyte as the named fallback | proposed |
| [0011](0011-nango-as-integration-hub.md) | Nango for the provider edge, sync logic stays in Ash | proposed |
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
| [0024](0024-audit-retention-and-erasure.md) | Audit retention: partition for age, crypto-shred for erasure | proposed |
| [0025](0025-log-shipping-and-review.md) | Logs ship to the customer's SIEM; review is evidence | proposed |
| [0026](0026-ai-governance-is-disclosure.md) | AI governance is disclosure, not a second authorization model | proposed |
| [0027](0027-feel-is-the-expression-language.md) | FEEL is the one expression language, and the engine is adopted rather than written | accepted |
| [0028](0028-decisions-are-dmn.md) | Decisions are DMN, measured against the TCK, in their own first-party package | accepted |
| [0029](0029-process-configuration-is-tenant-data.md) | Process and decision configuration is tenant data, defaulting to a platform baseline | accepted |
| [0030](0030-events-trigger-processes.md) | Events trigger processes through a dispatched cursor, not a handler | accepted |

Records 0001–0009, 0020–0023 and 0027–0030 are `accepted` and describe code that exists.
**0010–0019 and 0024–0026 are `proposed`: none of them is built.** They are here because a decision is cheapest to reason about — and cheapest to
*reverse* — while the alternatives are still fresh, and because
[thesis 6](../manifesto/06-reversibility.md) asks for the exit before the entrance. Three of them
record an answer that changed under verification, which is the main reason to write them down early.

0015 is the one deliberate straggler: its subject is built and demonstrated, and it stays `proposed`
because the specific negative test it named as its own acceptance criterion has not been written. A
record whose criterion is unmet does not get promoted for being nearly right.

Their sequencing, and the one rule they were all selected against, is [`../ROADMAP.md`](../ROADMAP.md).

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
