# ADR 0048 — A judgment is a predicate over any set

- **Status:** accepted (2026-10-02, Luke on S1-52: "Accepted. Go with recommendation for Q13." — Q13: one fact carries its admission grade; consumer-specific admission grades are the model).
- **Date:** 2026-09-28

## Context

ADRs 0038–0047 were written with one consumer in view: compliance. The examples are certificate clauses, the outcomes are
`compliant` and `unknown`, and the package that evaluates admitted facts, `ash_rules`, introduces itself as a compliance
tool. Once the records were accepted, the operator pointed out that the mechanism is not about compliance at all:

> It applies to more than just compliance, but also defining filters and search against any set.

That is right, and the reason is structural rather than a matter of reuse:

- **A judgment is a predicate.** "Does this passage state a limit of at least X?" is `supports_limit(passage, X)`. "Does
  this vendor do roof work?" is `does_roof_work(vendor)`. Each is a predicate over a subject. Once it is admitted it is a
  fact, a `{subject, predicate, value}` triple, which is already the only shape `ash_rules` evaluates.
- **A filter is a predicate over a set.** "Vendors in Toronto who do roof work and hold a current certificate" is the
  conjunction of one crisp predicate and two judged ones, evaluated over every vendor. A compliance rule is the same
  expression evaluated per subject, with an outcome attached.
- **Every surface that selects records is a consumer of the same vocabulary:**
  - ad hoc filters and search;
  - saved filters, segments and lists;
  - standing queries and alerts ("an awarded job whose contractor's coverage fact has lapsed");
  - routing and triage queues;
  - rules and compliance findings.

  Today each of those would grow its own private definition of "does roof work" — a tag somebody maintains, a keyword
  match, a column — and the definitions would drift apart.
- **The pieces already exist.**
  - `ash_rules` facts are subject–predicate–value triples.
  - Its bundles are content-hashed, serialisable IR.
  - It ships a per-subject evaluator and a Rete evaluator (`wongi`), which matches incrementally as facts arrive — the
    machinery a standing query needs.
  - Ash's filter expressions push down to SQL, and every API surface (JSON:API, GraphQL, AshPhoenix filter forms, A2UI
    reports) derives its filters from the same declarations.

  What is missing is the join: a judged predicate that is filterable like an attribute, and a set evaluator for the
  rule IR.

Generalising is also where the thesis's claimed value changes. [Thesis 8](../manifesto/08-models-observe-declarations-decide.md)'s
steelman narrowed the model's value to triage and verification. Filtering and search by meaning, over any set the
platform holds, is a much larger claim, and it needs the same discipline — in some ways more, because people act on
search results without reading a finding.

## Decision

**A declared question over a subject defines a predicate. Rules, filters, search, segments and standing queries are all
expressions over one vocabulary of predicates, crisp and judged alike. Compliance is one consumer among several.**

### One vocabulary

The fact schema is the vocabulary of every set expression. A crisp predicate is a condition on an attribute or a
relationship. A judged predicate is a declared question ([ADR 0039](0039-judgments-are-declared-questions.md)) whose
subject is any Ash resource — a vendor, a property, a work order, a note — not only a passage. Both appear in the same
schema, under the same names, with the same types.

A saved filter, a segment and a standing query are `ash_rules` bundles: content-hashed, versioned and activated like
any other bundle. The person who activates one is its author of record ([ADR 0047](0047-learning-produces-proposals.md)).

### Membership is three-valued

A judged predicate partitions a set three ways, not two:

| Partition | Meaning |
|---|---|
| **in** | an admitted fact says the predicate holds |
| **out** | an admitted fact says it does not |
| **unknown** | no admitted fact: never assessed, withheld by the band table, awaiting review, or stale |

`unknown` is always surfaced — as a count, and as an action to assess those subjects — and never folded into either
side. Negation is over admitted facts only: "vendors that do *not* do roof work" is the `out` partition, not everything
outside `in`. This is the guarantee that uncertainty never collapses to compliant, restated for sets: **uncertainty
never collapses to excluded, and never to included.** SQL's three-valued logic is the natural implementation, and the
query surface must not hide it behind a boolean.

### Queries read; instruments backfill

No model is called inside a read action, a filter, a sort or a calculation
([ADR 0038](0038-models-observe-declarations-decide.md)'s table, unchanged). A judged predicate compiles to an
expression over admitted facts, so a filter is a database query: indexable, paginated, composed with policies, and the
same cost on the thousandth call as on the first. The `unknown` partition is filled in only by:

- a materialisation job (an AshOban trigger, when a subject is created or changes), or
- an explicit, named, budgeted action a person runs ("assess these 40").

Both record observations, which the band table then admits or withholds; the filter re-reads.

### Scores order; facts decide

An unadmitted observation may **order** a list a person reads: relevance ranking, "most likely first", exploration.
Such an ordering is labelled as a model's, and it never decides **membership** in a set that something acts on. Those
actions — a bulk action, a notification, a process start, a rule outcome — read only admitted facts, and each may state
the minimum admission grade it accepts (for example, admitted by a person). This is thesis 8's law that ranking is not
existence, applied to search: a vector search that fails to return a record is not evidence that the record lacks the
property.

### Retrieval generates candidates; it never decides membership

Embedding search and lexical search, served in the zone ([ADR 0042](0042-in-zone-inference-leaving-the-zone-is-a-disclosure.md)),
do two jobs: they rank for exploration, and they choose which subjects to assess first when assessment has a budget.
They never place a subject in `in` or `out`.

### Exploratory predicates, and how search grows the registry

A person may search for something no declared question covers. The generative rung may translate the request into a
filter over declared predicates. The translation is a **proposal**, shown as an editable filter; what runs is the
declared expression, deterministically, as the person.

A term with no declared predicate may be run as an **exploratory question**:

- only over a bounded candidate set;
- only as an explicit action;
- producing observations, never facts;
- shown in the ordered, labelled tier only.

When an exploratory question recurs, it becomes a proposal for a declared question — declared, calibrated, given a band
table and activated like any other ([ADR 0047](0047-learning-produces-proposals.md)). Once activated it is filterable.
**Search demand proposes the registry; nothing enters it without a person activating it.**

### A fact is about a subject's state, at a time, in a scope

Every admitted fact records three things. Filters read them:

- **Subject state.** The fact records the hash of the state its question saw. When the subject changes in a way the
  question's state projection covers, the fact is **stale**: it joins `unknown` and is queued for reassessment. It never
  silently stays `in`.
- **Validity.** A predicate may declare an expiry. An expired fact is `unknown`.
- **Scope.** A predicate is either about the subject alone ("does roof work") or about the subject in a context ("the
  coverage is adequate for this customer's requirements"). A scoped fact is admitted, stored and filtered per context,
  and a filter always runs in the actor's context. The band table is chosen per scope already
  ([ADR 0041](0041-thresholds-are-dmn-earned-by-calibration.md)).

Filters answer "as of now" by default. "As of" questions read the event history ([ADR 0040](0040-record-dont-recompute.md)).

### One IR, three evaluators, proven equivalent

| Evaluator | Answers | Used by |
|---|---|---|
| Per-subject (`ash_rules` direct) | "what is the outcome for this subject, and why" | rules, findings, explanations |
| Set (compiled to an Ash query over facts) | "which subjects are in, out, unknown" | filters, search, segments, bulk selection |
| Incremental (`ash_rules` Rete) | "whose membership just changed" | standing queries, alerts, process starts |

The set evaluator is new work, and so is a property test: **for every subject, set membership equals the per-subject
outcome.** Two evaluators that can disagree would give two answers to one question, which is worse than one.

### The query surface is derived

Declaring a question over a resource derives, with no further code:

- a filterable, sortable tri-state field and a status field
  (`admitted_true | admitted_false | review | not_assessed | stale`), computed over the fact table in SQL;
- the same field in every surface that derives filters from declarations — JSON:API, GraphQL, AshPhoenix filter forms,
  A2UI reports and agent tooling.

This is [thesis 1](../manifesto/01-model-your-domain.md)'s *declare once, derive the rest*, applied to judged
predicates. The inference pipeline stays a separate subsystem that consumes declarations; what is derived here is a
read over facts, not a model call.

### Authorization is unchanged

A filter runs as the actor, through policies. A judged predicate cannot widen what the actor may see, and a fact is
readable only where its subject is. A judged predicate is never a row-access policy: that is law 3 of thesis 8,
unchanged. Filtering what a person asked to see is not the same thing as deciding what they are allowed to see.

### Interchange

The canonical form of a saved expression is the `ash_rules` IR. Whether saved filters and API filters should also be
imported and exported in a published standard is **open**. The candidates:

- CQL2 (OGC, with a JSON encoding), which is specified for filtering collections over HTTP;
- DMN FEEL unary tests, which are already in the stack.

The recommendation is a spike before any bespoke filter syntax is written.

## Does it consume ActorContext?

**Yes, and only as every read does.** Filters and searches are read actions run as the requesting actor through the
same policies; judged predicates are fields over facts the actor can read. Nothing computed from a model enters
`ActorContext`, and no judged predicate appears in a policy.

## Consequences

- `ash_judgments` gains a query surface:
  - the derived tri-state and status fields;
  - freshness and scope on facts;
  - the explicit assess action and the materialisation trigger;
  - labelled ordering by observation;
  - exploratory questions, restricted to bounded candidate sets.
- `ash_rules` gains a set evaluator (IR to Ash query) and the equivalence property test. Its introduction should lead
  with predicates over sets, and present compliance as the first consumer.
- `ash_evidence` is unchanged in kind. Grounding a predicate about a vendor in the atoms of its documents is the same
  mechanism as grounding one about a clause.
- The judgment-record RFC (S1-24) gains query-side requirements before it freezes: a subject reference, the
  subject-state hash, scope, validity, the admission grade, and indexes that support the set evaluator.
- The public demonstration should show three-valued search on synthetic data: the `unknown` partition surfaced, the
  assess action, labelled ordering.
- Search results, standing queries and segments carry the same provenance as findings: every `in` links to its fact,
  observation, instrument and band row.

## What it forecloses

- A model call in any read path, including "just for this one search".
- A boolean judged field that renders `unknown` as false, or as true.
- A bulk action, notification or process start driven by an unadmitted score.
- A second, private definition of a predicate that already has a declared question.
- An exploratory question promoted to a filter without declaration, calibration and activation.

## Reversal

If a set evaluator proves too costly to keep equivalent to the per-subject evaluator, filters can fall back to reading
materialised per-subject outcomes. That keeps the vocabulary and the three-valued rule and drops only the query-time
composition. Reversing the three-valued rule itself would reintroduce the failure thesis 8 exists to prevent, and would
take a superseding record.
