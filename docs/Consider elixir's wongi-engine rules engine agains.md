<img src="https://r2cdn.perplexity.ai/pplx-full-logo-primary-dark%402x.png" style="height:64px;margin-right:32px"/>

# Consider elixir's wongi-engine rules engine against my ash-enterprise GitHub project goals. How would a rules engine cleanly fit into the proposed architecture? In the past I've used rules engines to process each event and trigger events, which could be more elegant than just tying action triggers to bpmn processes and dmn nodes.. but it's just a more elegant way of defining a conditional action trigger based on an event.. questionable value? Imagine if the app we need to build on top of ash_enterprise needs a compliance engine (ie. To define compliance rules against subject, predicate, value facts which are derived from resource definitions in ash?) What about expanding ash to allow defining queries and calculated fields based on rules engine?

Imagine we had a bunch of resource entities with compliance rules that form a policy re 'is the customer compliant" and "these are the gaps"...

Best practices? What is the ash way here?

You’ve identified the right architectural tension: **Wongi should not become another workflow engine or replace Ash policies/calculations.** Its strongest fit is as a **derived-fact and policy-evaluation subsystem**—especially for cross-resource, explainable compliance—while Ash remains the authoritative domain model and mutation boundary.

## Recommended Boundary

| Concern | Primary owner |
| :-- | :-- |
| Resources, relationships, validation, persistence | Ash |
| Authorization and field visibility | Ash policies |
| Transactional invariants | Ash changes, validations, identities |
| Long-running orchestration and human tasks | BPMN |
| Decision tables with explicit inputs/outputs | DMN |
| Event transport and reliable delivery | Outbox/event bus |
| Cross-resource inference and compliance gap detection | Wongi |
| Durable compliance results and evidence | Ash compliance resources |

The useful distinction is:

- **Ash policies answer:** “May this actor perform this action?”
- **Ash validations answer:** “May this state transition commit?”
- **DMN answers:** “Given these inputs, what explicit decision follows?”
- **BPMN answers:** “What process should happen next?”
- **Wongi answers:** “Given the current fact set, what can we infer, which obligations are unsatisfied, and why?”

That last category becomes valuable when policy is **multi-hop, compositional, independently authored, and explanation-heavy**.

## Clean Architectural Fit

Treat Wongi as a **projection/evaluation engine behind an Ash boundary**, not as a framework-level peer that can mutate arbitrary resources.

```text
Ash resources
   │
   ├── domain events + transactional outbox
   │
   ▼
Fact projector
   │  subject / predicate / object / provenance / validity
   ▼
Policy evaluator (Wongi)
   │
   ├── inferred facts
   ├── findings/gaps
   ├── evidence graph
   └── requested effects
          │
          ▼
Ash actions / workflow commands
```

A good flow is:

1. An Ash action commits a domain change and an outbox event in the same transaction.
2. A projector converts relevant resource state into normalized facts.
3. Wongi updates the affected working memory and evaluates the applicable policy bundle.
4. The evaluator persists findings, inferred facts, evidence, and policy-version metadata through explicit Ash actions.
5. New or changed findings emit domain events.
6. BPMN consumes those events when remediation requires orchestration, approvals, timers, or human work.

This retains the elegance of event-triggered rules without allowing rules to become a hidden imperative application layer.

## Event Rules: Real Value or Syntax?

Your skepticism is justified. If a rule is only:

> On `vendor.created`, if `risk_score > 80`, start process X.

then it is usually just a more indirect event handler. An Ash notifier, reactor, or explicit event subscription is easier to discover, type-check, test, and operate.

A rule engine earns its place when several of these are true:

- Conditions combine facts from multiple resources or time periods.
- Rules derive intermediate concepts reused by other rules.
- Policies vary by jurisdiction, tenant, contract, or effective date.
- Rules must be changed independently from deployment.
- Users need “why compliant?” and “what is missing?” explanations.
- Partial updates should incrementally reevaluate only affected conclusions.
- Rules have priorities, exceptions, overrides, or interactions.
- The same policy logic supports batch assessment and event-driven reassessment.

So I would not model all automation as arbitrary `event -> rule -> event`. Instead, have rules emit **typed effect requests**:

```elixir
%Compliance.EffectRequested{
  effect_type: :start_remediation,
  subject_ref: {:vendor, vendor_id},
  finding_id: finding_id,
  policy_version_id: version_id,
  idempotency_key: "finding:#{finding_id}:remediation"
}
```

An application service then maps that request to a permitted Ash action or BPMN process. This provides retries, authorization, idempotency, auditability, and observability.

## Compliance Domain Model

Avoid treating a bare triple as the complete fact model. Compliance needs provenance and time semantics.

```elixir
Compliance.Fact
- tenant_id
- subject_type
- subject_id
- predicate
- value_type
- value
- source_resource
- source_record_id
- source_attribute
- observed_at
- valid_from
- valid_until
- evidence_ref
- fact_version
```

Then define durable policy concepts:

```text
Policy
PolicyVersion
RuleDefinition
PolicyAssignment
Assessment
RequirementResult
Finding
EvidenceLink
Waiver / Exception
EvaluationRun
EffectRequest
```

The most important design choice is to make **requirements first-class**. Instead of merely deriving `customer.compliant = false`, produce one result per requirement:

```elixir
%RequirementResult{
  requirement_key: "kyc.beneficial_owners.verified",
  status: :fail,
  subject_ref: {:customer, customer_id},
  expected: "all beneficial owners verified",
  actual: ["owner-123"],
  evidence: [...],
  rule_id: "...",
  policy_version_id: "...",
  evaluated_at: ...
}
```

Overall compliance is then an aggregation over requirement results:

```text
compliant? =
  no mandatory requirement is fail or unknown,
  after applying valid waivers
```

This naturally supports “is the customer compliant?” and “what are the gaps?” while avoiding an opaque Boolean.

Use at least four states:

- `pass`
- `fail`
- `unknown`
- `not_applicable`

Do not collapse `unknown` into `fail` unless an explicit policy says missing evidence is itself noncompliance.

## Mapping Ash Resources to Facts

Do not automatically expose every Ash field as a fact. Build an explicit, versioned fact schema or DSL close to the resource definition:

```elixir
defmodule MyApp.Customers.Customer do
  use Ash.Resource

  attributes do
    uuid_primary_key :id
    attribute :jurisdiction, :atom
    attribute :status, :atom
  end

  relationships do
    has_many :certifications, MyApp.Compliance.Certification
  end

  compliance_facts do
    fact :jurisdiction, from: :jurisdiction
    fact :active, calculate: expr(status == :active)

    fact :has_valid_kyc,
      projector: {MyApp.Compliance.Projectors.KYC, :valid?},
      dependencies: [:id, :certifications]
  end
end
```

Whether implemented through Spark DSL extensions or plain modules, the contract should specify:

- Stable predicate name.
- Value type.
- Cardinality.
- Source and provenance.
- Dependencies that invalidate it.
- Tenant and authorization scope.
- Whether absence means false, unknown, or no fact.
- Whether it may contain sensitive data.

I would initially keep this as a library-owned DSL rather than modifying Ash itself. If the abstraction proves broadly useful, then consider an Ash extension.

## Rules Should Be Pure

Keep Wongi rules focused on matching and deriving conclusions:

```elixir
rule "active regulated customer requires valid KYC" do
  forall {
    has :customer, "status", :active
    has :customer, "jurisdiction", :regulated
    neg :customer, "has_valid_kyc", true
  }

  derive :customer, "gap", "kyc.valid_required"
end
```

The exact Wongi syntax may differ, but the conceptual split should remain:

- **LHS:** match facts.
- **RHS:** derive a fact, requirement result, finding, or effect request.
- **Never:** directly update arbitrary domain state from the RHS.

This makes replay and deterministic testing much safer.

## Calculated Fields

I would **not** make arbitrary Ash calculations execute a mutable Wongi session inline. That introduces hidden I/O, uncertain latency, difficult dependency tracking, awkward authorization semantics, and non-obvious query behavior.

Use three integration levels:


| Requirement | Ash-oriented implementation |
| :-- | :-- |
| Display the latest compliance result | Relationship or calculation reading a persisted `Assessment` |
| Filter/sort customers by compliance | Materialized status/findings stored in Postgres |
| Ad hoc “what if?” evaluation | Explicit action calling a stateless policy evaluator |
| Simple single-resource calculation | Native Ash expression calculation |
| SQL-translatable cross-resource logic | Ash calculation/aggregate or database view |
| Complex recursive inference | Wongi, then persist the result |

For example:

```elixir
calculations do
  calculate :compliant?, :boolean,
    expr(latest_assessment.status == :compliant)

  calculate :compliance_gap_count, :integer,
    expr(count(open_findings))
end
```

The underlying assessment is maintained asynchronously or synchronously according to business requirements, but querying stays Ash-native.

## Queries Based on Rules

Rule engines and database query planners solve different problems. Wongi is effective at evaluating a bounded working memory; Ash data layers are designed to filter, sort, paginate, authorize, and push work into Postgres or another store.

Therefore, avoid a generic API such as:

```elixir
Ash.Query.filter(Customer, satisfies_rule("policy-x"))
```

unless the rule compiler can safely produce an Ash expression or SQL predicate.

A better hierarchy is:

1. Compile simple declarative rules into Ash expressions.
2. Compile relational rules into SQL views or materialized views where practical.
3. Use Wongi for non-SQL inference.
4. Persist inferred membership/status so normal Ash queries can filter it.
5. Offer explicit evaluate actions for hypothetical or unpersisted inputs.

An Ash interface could look like:

```elixir
action :evaluate_compliance, :map do
  argument :policy_version_id, :uuid, allow_nil?: false
  argument :as_of, :utc_datetime, allow_nil?: false

  run MyApp.Compliance.Actions.Evaluate
end
```

And query-oriented fields can read the resulting projection:

```elixir
has_one :current_compliance_assessment,
  MyApp.Compliance.Assessment do
  filter expr(current == true)
end
```


## BPMN and DMN Relationship

Rules, DMN, and BPMN should form a pipeline rather than compete:

```text
Domain event
  → refresh facts
  → evaluate policy rules
  → create/change finding
  → choose remediation with DMN, if needed
  → orchestrate remediation with BPMN
```

A useful division is:

- Wongi detects and explains policy state.
- DMN makes a bounded business decision from explicit inputs.
- BPMN coordinates the lifecycle that follows.
- Ash enforces every durable state transition.

For example, Wongi determines that a vendor lacks required cyber insurance; DMN selects the remediation tier based on spend and data sensitivity; BPMN runs document collection, review, escalation, and expiry timers.

## Synchronous vs Asynchronous

Use synchronous evaluation only for narrow policies required to accept or reject a command:

```text
Ash action
  → construct bounded facts
  → evaluate blocking policy
  → reject or continue
```

Use asynchronous evaluation for broad cross-resource compliance:

```text
commit
  → outbox
  → incremental evaluation
  → persist assessment/findings
  → notify/workflow
```

Do not rely on an asynchronous compliance projection to enforce a hard transactional invariant. If “a payment must never be released while sanctions screening is unresolved,” put a conservative guard in the payment action as well.

## Multi-Tenancy and Lifecycle

For enterprise use, partition working memory at least by tenant and often by policy scope. A single global mutable Wongi network risks cross-tenant leakage, memory growth, and difficult recovery.

You will also need:

- Versioned policy bundles with effective dates.
- Evaluation against an `as_of` timestamp.
- Replay from source facts/events.
- Idempotent finding creation and closure.
- Explicit retractions when source facts change.
- Dependency metadata for targeted reevaluation.
- Deterministic conflict resolution.
- Audit records containing rule version, matched facts, and evidence.
- Shadow evaluation before activating a new policy.
- A reconciliation job that periodically compares projections with source state.

Wongi’s RETE-style incremental evaluation is attractive here, but persistence and recovery are your responsibility. Treat in-memory working memory as rebuildable state, not the source of truth.

## Suggested Ash APIs

Hide the engine behind domain-specific behaviours:

```elixir
defmodule MyApp.Compliance.Engine do
  @callback evaluate(
    policy_version :: Ash.UUID.t(),
    subject :: struct(),
    opts :: keyword()
  ) :: {:ok, MyApp.Compliance.Result.t()} | {:error, term()}

  @callback apply_changes(
    partition :: term(),
    assertions :: [MyApp.Compliance.Assertion.t()],
    retractions :: [MyApp.Compliance.FactRef.t()]
  ) :: {:ok, [MyApp.Compliance.Delta.t()]} | {:error, term()}
end
```

Keep Wongi-specific terms inside the adapter:

```text
Compliance.Engine
└── Compliance.Engine.Wongi
```

That lets you later replace Wongi with generated Elixir, SQL, Datalog, OPA, or a hosted policy engine without rewriting the domain model.

## Practical Adoption Path

1. Build one vertical slice: customer KYC compliance.
2. Define explicit fact projectors for 5–10 stable predicates.
3. Model requirement results and findings as Ash resources.
4. Evaluate through an explicit Ash action.
5. Persist status, gaps, evidence, and policy version.
6. Emit typed `finding.opened`, `finding.resolved`, and `assessment.changed` events.
7. Let BPMN respond only to those durable domain events.
8. Add incremental Wongi sessions only after profiling shows full reevaluation is too costly.
9. Add a resource DSL only after several resources reveal a stable projection pattern.
10. Consider compiling a restricted policy DSL to Ash expressions, SQL, or Wongi based on rule shape.

## Bottom Line

The “Ash way” is to keep **data, actions, authorization, and durable state explicit**, while extending behavior through well-bounded actions, calculations, relationships, notifiers, and domain services. Wongi fits well as a private implementation detail of a compliance domain—not as a universal callback mechanism wired into every Ash action.

The strongest architecture is:

> **Ash resources produce governed facts; Wongi derives compliance conclusions and gaps; Ash persists those conclusions; DMN chooses bounded responses; BPMN orchestrates remediation.**

If the initial rules are only conditional event handlers, Wongi adds questionable value. If the platform needs versioned, cross-resource, explainable policies with missing-evidence analysis and incremental reevaluation, it becomes a meaningful architectural component rather than nicer trigger syntax.

---

# This seems like we're building the concept of compliance and compliance gaps into ash_enterprise directly.. supporting the idea that any resource may have compliance needs.. But, shouldn't we expose the rules engine in an abstract way and then use those core primitives to implement compliance? Like, if "vendor compliance for a given contract" needed modelling, we'd have a resource for the relationship between vendor and contract and then define compliance for that resource entity somehow?

Is there an established form for rules engines applied to compliance that we could establish as another layer of abstraction over raw rules?

How would we allow per tenant or arbitrarily layered rulesets that allow us to define a form of compliance and base ruleset, but allow customer config rules? Versioned rulesets too..

Is wongi a poor fit here vs other options??

You’re right: **compliance should be an application built from generic reasoning primitives, not a concept embedded into `ash_enterprise`’s core.** The core abstraction should model scoped facts, versioned rule programs, evaluations, conclusions, evidence, and effects; a compliance package then specializes those into requirements, assessments, and gaps.

---

# Elaborate. Update report. Is there an authoritative source of design on this we can refer to? What about my other questions.abive?

I updated and expanded the report, including direct answers to the earlier questions.

The strongest authoritative foundation is a combination of **NIST OSCAL** for control catalogs and tailoring, **XACML** for policy-combining semantics, **OPA** for immutable bundle distribution, **Cedar** for schema validation, and **NIST SP 800-53A** for evidence and findings. Wongi remains suitable as a replaceable inference kernel—not as the policy system of record. [^3_1][^3_2][^3_3][^3_4][^3_5]

The report also covers DSL design, global-versus-tenant precedence, immutable versioning, auditability, evidence, side effects, API boundaries, multitenancy, alternatives, production-readiness criteria, and a phased POC roadmap. [^3_6]

<span style="display:none">[^3_10][^3_100][^3_101][^3_102][^3_103][^3_104][^3_105][^3_106][^3_107][^3_108][^3_109][^3_11][^3_110][^3_111][^3_112][^3_113][^3_114][^3_115][^3_116][^3_117][^3_118][^3_119][^3_12][^3_120][^3_121][^3_122][^3_123][^3_124][^3_125][^3_126][^3_127][^3_128][^3_129][^3_13][^3_130][^3_131][^3_14][^3_15][^3_16][^3_17][^3_18][^3_19][^3_20][^3_21][^3_22][^3_23][^3_24][^3_25][^3_26][^3_27][^3_28][^3_29][^3_30][^3_31][^3_32][^3_33][^3_34][^3_35][^3_36][^3_37][^3_38][^3_39][^3_40][^3_41][^3_42][^3_43][^3_44][^3_45][^3_46][^3_47][^3_48][^3_49][^3_50][^3_51][^3_52][^3_53][^3_54][^3_55][^3_56][^3_57][^3_58][^3_59][^3_60][^3_61][^3_62][^3_63][^3_64][^3_65][^3_66][^3_67][^3_68][^3_69][^3_7][^3_70][^3_71][^3_72][^3_73][^3_74][^3_75][^3_76][^3_77][^3_78][^3_79][^3_8][^3_80][^3_81][^3_82][^3_83][^3_84][^3_85][^3_86][^3_87][^3_88][^3_89][^3_9][^3_90][^3_91][^3_92][^3_93][^3_94][^3_95][^3_96][^3_97][^3_98][^3_99]</span>

<div align="center">⁂</div>

[^3_1]: https://pages.nist.gov/OSCAL/learn/concepts/layer/control/profile/

[^3_2]: https://pages.nist.gov/OSCAL/learn/tutorials/implementation/simple-component-definition/

[^3_3]: https://pages.nist.gov/OSCAL-Reference/models/v1.1.2/component-definition/json-definitions/

[^3_4]: https://docs.oasis-open.org/xacml/3.0/xacml-3.0-core-spec-os-en.html

[^3_5]: https://docs.oasis-open.org/xacml/3.0/xacml-3.0-core-spec-en.html

[^3_6]: https://openpolicyagent.org/docs/management-bundles

[^3_7]: https://openpolicyagent.org/docs/management-status

[^3_8]: https://openpolicyagent.org/docs/management-discovery

[^3_9]: https://www.openpolicyagent.org/docs/management-introduction

[^3_10]: https://docs.cedarpolicy.com/policies/validation.html

[^3_11]: https://docs.cedarpolicy.com/

[^3_12]: https://docs.cedarpolicy.com/schema/schema.html

[^3_13]: https://docs.cedarpolicy.com/other/security.html

[^3_14]: https://csrc.nist.gov/pubs/sp/800/53/a/r5/final

[^3_15]: https://nvlpubs.nist.gov/nistpubs/specialpublications/nist.sp.800-53ar4.pdf

[^3_16]: https://docs.oasis-open.org/xacml/3.0/xacml-3.0-core-spec-csprd04-en.html

[^3_17]: https://docs.oasis-open.org/xacml/xacml-3.0-combalgs/v1.0/csprd03/xacml-3.0-combalgs-v1.0-csprd03.html

[^3_18]: https://github.com/ash-project/spark

[^3_19]: https://hexdocs.pm/spark/0.2.4/get-started-with-spark.html

[^3_20]: https://github.com/ash-project/ash/blob/main/documentation/topics/advanced/writing-extensions.md

[^3_21]: https://openpolicyagent.org/docs/policy-language

[^3_22]: https://hexdocs.pm/ash/1.47.8/expressions.html

[^3_23]: https://github.com/ash-project/ash/blob/main/documentation/topics/resources/aggregates.md

[^3_24]: https://www.matec-conferences.org/articles/matecconf/pdf/2019/01/matecconf_cmes2018_02007.pdf

[^3_25]: http://arxiv.org/pdf/2110.01909.pdf

[^3_26]: https://arxiv.org/abs/1603.07466

[^3_27]: https://pmc.ncbi.nlm.nih.gov/articles/PMC5601943/

[^3_28]: https://pmc.ncbi.nlm.nih.gov/articles/PMC10406295/

[^3_29]: https://pmc.ncbi.nlm.nih.gov/articles/PMC12025022/

[^3_30]: https://www.omg.org/spec/DMN/1.5/About-DMN

[^3_31]: https://docs.oasis-open.org/legalruleml/legalruleml-core-spec/v1.0/cs01/legalruleml-core-spec-v1.0-cs01.html

[^3_32]: https://docs.oasis-open.org/legalruleml/legalruleml-core-spec/v1.0/legalruleml-core-spec-v1.0.html

[^3_33]: https://docs.oasis-open.org/legalruleml/legalruleml-core-spec/v1.0/csprd01/legalruleml-core-spec-v1.0-csprd01.html

[^3_34]: https://docs.oasis-open.org/legalruleml/legalruleml-core-spec/v1.0/cs02/legalruleml-core-spec-v1.0-cs02.html

[^3_35]: https://www.omg.org/spec/DMN/1.5/Beta1/About-DMN

[^3_36]: https://www.omg.org/spec/DMN/1.5/Beta1/PDF

[^3_37]: https://pages.nist.gov/OSCAL/resources/concepts/layer/assessment/assessment-results/

[^3_38]: https://www.omg.org/spec/DMN/machine-readable

[^3_39]: https://docs.oasis-open.org/legalruleml/legalruleml-core-spec/v1.0/os/legalruleml-core-spec-v1.0-os.html

[^3_40]: https://pages.nist.gov/OSCAL/learn/concepts/layer/assessment/assessment-results/

[^3_41]: https://www.omg.org/dmn/

[^3_42]: https://www.omg.org/spec/DMN/1.7/Beta1/About-DMN

[^3_43]: https://docs.oasis-open.org/legalruleml/legalruleml-core-spec/v1.0/csprd02/legalruleml-core-spec-v1.0-csprd02.html

[^3_44]: https://docs.oasis-open.org/legalruleml/legalruleml-core-spec/v1.0/csprd01/rdfs/

[^3_45]: https://nvlpubs.nist.gov/nistpubs/jres/106/1/j61hog.pdf

[^3_46]: http://datascience.codata.org/articles/10.5334/dsj-2019-030/galley/861/download/

[^3_47]: https://www.mdpi.com/2218-2004/8/3/56/pdf

[^3_48]: https://acta.imeko.org/index.php/acta-imeko/article/download/1403/2790

[^3_49]: https://pmc.ncbi.nlm.nih.gov/articles/PMC8594275/

[^3_50]: https://pages.nist.gov/OSCAL/learn/concepts/layer/

[^3_51]: https://pages.nist.gov/OSCAL/learn/tutorials/control/

[^3_52]: https://pages.nist.gov/OSCAL/learn/tutorials/

[^3_53]: https://pages.nist.gov/OSCAL/resources/concepts/layer/

[^3_54]: https://pages.nist.gov/OSCAL/resources/concepts/layer/control/profile/

[^3_55]: https://openpolicyagent.org/docs/management-decision-logs

[^3_56]: https://pages.nist.gov/OSCAL/learn/concepts/layer/control/

[^3_57]: https://pages.nist.gov/OSCAL/learn/tutorials/control/basic-profile/

[^3_58]: https://pages.nist.gov/OSCAL/learn/concepts/layer/control/catalog/

[^3_59]: https://docs.drools.org/7.64.0.Final/drools-docs/html_single/

[^3_60]: https://docs.drools.org/5.5.0.Final/droolsjbpm-introduction-docs/pdf/droolsjbpm-introduction-docs.pdf

[^3_61]: https://www.openpolicyagent.org/docs/monitoring

[^3_62]: https://www.openpolicyagent.org/docs/debugging

[^3_63]: https://docs.drools.org/5.3.0.Beta1/droolsjbpm-introduction-docs/html/ch02.html

[^3_64]: https://www.mdpi.com/1424-8220/22/8/2984/pdf

[^3_65]: https://pmc.ncbi.nlm.nih.gov/articles/PMC9026700/

[^3_66]: https://arxiv.org/pdf/2403.10092.pdf

[^3_67]: https://arxiv.org/pdf/2306.12819.pdf

[^3_68]: https://arxiv.org/pdf/2005.07160.pdf

[^3_69]: http://arxiv.org/pdf/1809.02724.pdf

[^3_70]: http://downloads.hindawi.com/journals/mpe/2016/7608408.pdf

[^3_71]: https://pmc.ncbi.nlm.nih.gov/articles/PMC9959851/

[^3_72]: https://docs.oasis-open.org/xacml/3.0/xacml-3.0-core-spec-csd06-en.html

[^3_73]: https://docs.oasis-open.org/xacml/3.0/xacml-3.0-core-spec-cs-01-en.html

[^3_74]: https://docs.oasis-open.org/xacml/3.0/xacml-3.0-core-spec-cd-04-en.html

[^3_75]: https://docs.oasis-open.org/xacml/3.0/errata01/csprd01/xacml-3.0-core-spec-errata01-csprd01-complete.pdf

[^3_76]: https://docs.oasis-open.org/xacml/3.0/xacml-3.0-core-spec-cd-1-en.doc

[^3_77]: https://docs.oasis-open.org/xacml/3.0/xacml-3.0-core-spec-cs02-en.pdf

[^3_78]: https://docs.oasis-open.org/xacml/3.0/xacml-3.0-core-spec-cd-03-en.doc

[^3_79]: https://docs.oasis-open.org/xacml/xacml-3.0-dyn-attr/v1.0/cs01/xacml-3.0-dyn-attr-v1.0-cs01.html

[^3_80]: https://docs.oasis-open.org/xacml/3.0/xacml-3.0-core-spec-cos01-en.doc

[^3_81]: https://docs.oasis-open.org/xacml/3.0/xacml-3.0-administration-v1-spec-cs-01-en.pdf

[^3_82]: https://docs.oasis-open.org/xacml/3.0/xacml-3.0-administration-v1-spec-cd-03-en.html

[^3_83]: https://arxiv.org/pdf/2212.06606.pdf

[^3_84]: https://www.cambridge.org/core/services/aop-cambridge-core/content/view/21438B9B94F5B326921DE6671F9F5629/S147106842300011Xa.pdf/div-class-title-an-asp-framework-for-the-refinement-of-authorization-and-obligation-policies-div.pdf

[^3_85]: http://arxiv.org/pdf/2405.15342.pdf

[^3_86]: https://www.mdpi.com/1424-8220/22/5/1952/pdf

[^3_87]: https://arxiv.org/pdf/2104.06051.pdf

[^3_88]: http://arxiv.org/pdf/2205.14280.pdf

[^3_89]: https://www.mdpi.com/2073-431X/9/2/28/pdf

[^3_90]: https://openpolicyagent.org/docs/ocp/api-reference

[^3_91]: https://www.openpolicyagent.org/docs/archive

[^3_92]: https://openpolicyagent.org/docs/cli

[^3_93]: https://docs.cedarpolicy.com/policies/level-validation.html

[^3_94]: https://openpolicyagent.org/docs/external-data

[^3_95]: https://openpolicyagent.org/docs/ocp

[^3_96]: https://arxiv.org/pdf/1905.09034.pdf

[^3_97]: https://arxiv.org/pdf/2503.03826.pdf

[^3_98]: https://arxiv.org/pdf/1703.08219.pdf

[^3_99]: https://pmc.ncbi.nlm.nih.gov/articles/PMC8122984/

[^3_100]: https://github.com/ash-project/spark/blob/main/lib/spark/dsl/extension.ex

[^3_101]: https://deepwiki.com/ash-project/ash/2.8-multitenancy

[^3_102]: https://deepwiki.com/ash-project/ash/12.1-extension-system

[^3_103]: https://deepwiki.com/ash-project/spark/6.2-creating-your-first-extension

[^3_104]: https://github.com/ash-project/ash

[^3_105]: https://libraries.io/hex/ash_commanded

[^3_106]: https://hexdocs.pm/spark/1.1.55/get-started-with-spark.html

[^3_107]: https://github.com/ash-project/ash/blob/main/documentation/topics/development/development-utilities.md

[^3_108]: https://hexdocs.pm/spark/1.1.26/get-started-with-spark.html

[^3_109]: https://deepwiki.com/diffo-dev/ash_neo4j/3.2-dsl-validation-system

[^3_110]: https://arxiv.org/pdf/2107.12850.pdf

[^3_111]: https://jurnal.unidha.ac.id/index.php/jteksis/article/download/898/645

[^3_112]: https://arxiv.org/pdf/1910.04293.pdf

[^3_113]: https://arxiv.org/pdf/1710.01441.pdf

[^3_114]: https://pmc.ncbi.nlm.nih.gov/articles/PMC4865286/

[^3_115]: https://pmc.ncbi.nlm.nih.gov/articles/PMC4865287/

[^3_116]: https://pmc.ncbi.nlm.nih.gov/articles/PMC5082750/

[^3_117]: https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-53ar4.pdf

[^3_118]: https://pages.nist.gov/OSCAL-Reference/models/v1.2.1/component-definition/xml-definitions/

[^3_119]: https://pages.nist.gov/OSCAL-Reference/models/v1.1.2/component-definition/json-index/

[^3_120]: https://pages.nist.gov/OSCAL-Reference/models/v1.2.0/component-definition/json-definitions/

[^3_121]: https://pages.nist.gov/OSCAL-Reference/models/v1.1.1/component-definition/xml-reference/

[^3_122]: https://pages.nist.gov/OSCAL-Reference/models/v1.2.0/component-definition/xml-reference/

[^3_123]: https://pages.nist.gov/OSCAL-Reference/models/v1.1.0/component-definition/xml-definitions/

[^3_124]: https://pages.nist.gov/OSCAL-Reference/models/v1.0.2/component-definition/json-index/

[^3_125]: https://pages.nist.gov/OSCAL-Reference/models/develop/component-definition/xml-reference/

[^3_126]: https://nvlpubs.nist.gov/nistpubs/legacy/sp/nistspecialpublication800-53a.pdf

[^3_127]: https://pages.nist.gov/OSCAL-Reference/models/v1.1.2/component-definition/xml-reference/

[^3_128]: https://www.perplexity.ai/search/788ccfaf-4f82-47b2-bdbb-84b68874a7a7

[^3_129]: https://www.perplexity.ai/search/b8ffb34e-73a4-46a0-8a62-1b25e6a84fe8

[^3_130]: https://www.perplexity.ai/search/b24e225d-b70b-4d2c-9b54-8d01a2c35ebc

[^3_131]: https://www.perplexity.ai/search/4d81053a-94ae-4f41-83ef-1bf6f78d80a2


---

## Direct answer

Your desired mode is the right one: run `ash_strangler` as a **projection and observation boundary**, not as an attempt to pretend that legacy writes were Ash actions.

The cleanest design is:

```text
Legacy database write
        │
        ├── durable change capture
        │       └── source change envelope
        │
        ├── canonical projection into ash_enterprise
        │       └── ordinary Ash write, attributed to a system actor
        │
        ├── audit event in ash_enterprise
        │
        └── compliance reevaluation
                └── findings, evidence, and decision history
```

The important distinction is that a legacy database change has **two different meanings**:

1. **The legacy action itself** — who or what changed the legacy system.
2. **The new-system projection** — the process by which `ash_enterprise` observed and represented that change.

Those must not be recorded as though they were the same action.

## What the repository already provides

The current `ash_strangler` design is a strong fit for the first half of this architecture. Its listener can receive PostgreSQL notifications, re-read the affected record through Ash, and produce a notification that downstream Ash code can consume as if it came through the Ash notification layer. The package deliberately avoids depending directly on Phoenix PubSub and uses a resource-level opt-in such as `notify? true`.

That is useful for **fast propagation**, but the repository documentation is explicit that PostgreSQL `NOTIFY` is at-most-once, in-memory, lost during listener downtime, and unsuitable as an audit trail. Therefore, `pg_notify` should be treated as a wake-up signal, not as the authoritative event stream.

This distinction matters especially for your use case. You want a complete user-action log and compliance history, so the system needs a durable source of change events. The elegant design is to pair the existing notification path with a durable change ledger.

## Recommended architecture

### 1. Capture legacy changes durably

Use a legacy-side change envelope, ideally produced by one of these mechanisms:


| Mechanism | Role | Suitability |
| :-- | :-- | :-- |
| `pg_notify` | Low-latency wake-up | Useful fast path, not durable |
| Audit/change table populated by triggers | Durable row-level history | Good if trigger overhead is acceptable |
| Logical replication / WAL decoding | Durable ordered database changes | Strongest long-term option |
| Legacy application instrumentation | User/action context | Valuable for actor attribution, but incomplete if writes bypass the application |
| Periodic reconciliation query | Recovery mechanism | Required regardless of the primary path |

The most practical near-term design is:

```text
AFTER INSERT/UPDATE/DELETE trigger
    → legacy_change_events table
    → pg_notify('ash_strangler_wakeup', event_id)
```

The trigger should write the complete event to the durable table and send only a small identifier through `NOTIFY`.

For example:

```text
legacy_change_events
- id
- source_system
- source_table
- source_schema
- operation
- primary_key
- old_row
- new_row
- changed_columns
- transaction_id
- transaction_timestamp
- source_user
- source_request_id
- source_correlation_id
- actor_confidence
- emitted_at
- processed_at
```

The trigger must be part of the same database transaction as the legacy mutation. If the transaction rolls back, neither the business change nor the change event exists. If it commits, the event is durable even if the new Ash application is offline.

`pg_notify` then acts as an optimization:

```text
NOTIFY payload: {"change_id": 123456}
```

The listener receives the identifier, claims or reads the corresponding durable event, and processes it. If the listener was offline, a reconciliation worker finds unprocessed events later.

### 2. Do not write directly into the audit log

The legacy change event should not be inserted directly into `audit_events` unless it is already in the exact shape and semantics expected by the new audit system.

Instead, use a dedicated ingestion/projection action:

```text
AshStrangler.Ingestion.ProjectLegacyChange
```

That action should:

1. Load the durable legacy change envelope.
2. Resolve the target canonical resource and identity.
3. Translate old-schema values into canonical values.
4. Determine the tenant or organization.
5. Resolve actor attribution.
6. Create or update the canonical projection.
7. Record provenance linking the projection to the source event.
8. Cause the normal Ash audit machinery to record the projection write.
9. Schedule or emit compliance reevaluation.

This preserves the existing `ash_enterprise` principle that ordinary resource writes produce ordinary audit events, while making the source of the write explicit.

The resulting audit trail would look conceptually like this:

```text
Audit event A:
  source: legacy_application
  event_type: legacy_change_observed
  actor: user-123 or legacy-service-x
  source_event_id: 123456
  source_table: legacy_customer
  operation: update

Audit event B:
  source: ash_strangler_projection
  event_type: canonical_projection_updated
  actor: system:legacy_projection
  source_event_id: 123456
  canonical_resource: AshEnterprise.Accounts.Customer
  canonical_record_id: ...
```

That gives you both truths:

- “User 123 changed the legacy customer record.”
- “The new platform projected that change at time T using bundle/version V.”

Do not attribute the projection itself to the human actor. The actor caused the original legacy action, but the new system performed the projection. The audit record should retain both identities.

## Actor attribution

Your existing `ash_enterprise` design already has the right conceptual model: human actors, system actors, jobs, migrations, and replays should be distinct. The strangler path should extend that model rather than leave `user_id` null.

Use a source-aware attribution structure:

```text
actor
- kind: human | service | system | unknown
- source_system
- source_actor_id
- canonical_actor_id
- display_name_snapshot
- confidence
- resolution_method
```

A practical resolution order is:

1. A legacy user identifier that maps directly to a canonical user.
2. A legacy service identity mapped to a named system actor.
3. A source request or session identifier that can be joined to an application activity log.
4. A trusted integration identity.
5. An explicit `unknown` or `unattributed` actor.

Do not infer a human actor merely because a database connection or service account performed the write. If the only reliable fact is that the legacy application performed it, record:

```text
actor_kind: service
actor: legacy_application
human_actor: unknown
attribution_confidence: none
```

That is much more defensible than inventing a person.

The event metadata should preserve:

```text
- source_actor_id
- canonical_actor_id
- source_session_id
- source_request_id
- source_correlation_id
- source_ip, if trustworthy and appropriate
- attribution_method
- attribution_confidence
- impersonator_id, if supplied
```

The original source metadata should be immutable. If actor resolution improves later, create a separate attribution-resolution record rather than rewriting history.

## How this fits `ash_enterprise`

The repository appears to have several especially useful foundations already:

- A central append-only audit log.
- Tenant-scoped audit chains.
- Tamper-evident hashing.
- Correlation IDs.
- Explicit system actors.
- Projected legacy resources.
- Trigger cursors and dispatch records.
- A process-trigger model based on reading the audit chain.
- A deliberate separation between the audit log and process/evaluation records.

The most important adjustment is architectural: the existing audit log should become the **durable change feed for the new platform**, while the legacy database needs its own durable ingress ledger before anything is projected into Ash.

There should be three distinct streams:

```text
legacy_change_events
    Source facts from the old system.

audit_events
    Canonical platform mutations and observed governance events.

compliance_evaluations
    Results of evaluating controls against facts and evidence.
```

They should be linked, not collapsed.

## Compliance reevaluation

The compliance engine should not initially depend on Ash actions being invoked by users. It should react to **facts and durable events**.

That means defining compliance rules against a canonical fact model:

```text
fact(subject, predicate, object, observed_at, source, confidence)
```

Examples:

```text
fact(customer_42, :status, :active)
fact(customer_42, :owner_id, user_17)
fact(customer_42, :legacy_source_id, "C-10042")
fact(customer_42, :last_reviewed_at, ~U[2026-09-01 14:00:00Z])
fact(customer_42, :projection_revision, 91)
```

A rule should be declarative and independent of the action that produced the fact:

```text
when customer.status == :active
and customer.last_reviewed_at is older than 90 days
then finding(
  control: "CC7.2",
  status: :noncompliant,
  severity: :medium,
  subject: customer
)
```

That makes the rule reevaluable when:

- A legacy change arrives.
- A canonical projection changes.
- New evidence is collected.
- A control definition changes.
- A tenant override changes.
- Time itself causes a condition to expire.
- A historical bundle is replayed.

The rule should not be attached to `Customer.update` or any particular Ash action. It should be attached to a **fact dependency set**.

## Event-driven reevaluation model

Use a dependency index:

```text
rule_dependencies
- rule_revision_id
- fact_type
- resource_type
- attribute
- relationship
- control_id
```

When a change arrives, determine which facts may have changed and enqueue only affected evaluations.

For example:

```text
legacy customer update
        │
        ├── canonical customer projection updated
        │
        ├── facts changed:
        │     customer.status
        │     customer.owner
        │     customer.last_reviewed_at
        │
        ├── dependency index finds affected rules
        │
        └── evaluate:
              CC6.1 rules
              CC7.2 rules
              tenant-specific customer rules
```

The processing flow should be:

```text
source event
  → canonical fact extraction
  → affected-rule lookup
  → idempotent evaluation job
  → evaluation record
  → finding upsert or append-only finding revision
  → explanation/provenance record
```

Use Oban or the process-trigger machinery for asynchronous evaluation. The event should wake the system quickly, but a cursor-based sweep must remain the recovery mechanism.

## Evaluation records

Do not make the audit log carry the entire compliance result. Your existing design correctly treats evaluations as their own append-only evidence records.

A compliance evaluation should contain:

```text
ComplianceEvaluation
- id
- organization_id
- subject_type
- subject_id
- control_id
- rule_revision_id
- policy_bundle_revision
- fact_snapshot_hash
- evaluated_at
- status
- result
- missing_facts
- evaluator_version
- correlation_id
- source_event_id
```

A finding should contain:

```text
ComplianceFinding
- id
- organization_id
- evaluation_id
- control_id
- subject_type
- subject_id
- status
- severity
- first_seen_at
- last_seen_at
- resolved_at
- explanation_id
- remediation_reference
```

The evaluation is the answer to:

> What did the engine decide, using which policy and facts?

The audit event is the answer to:

> What changed in the platform?

The evidence record is the answer to:

> What supports this conclusion?

## The read-only future API

Your proposed future endpoint is very reasonable. It should expose **derived compliance state**, not raw policy internals or the entire audit log.

For example:

```text
GET /api/compliance/v1/controls
GET /api/compliance/v1/findings
GET /api/compliance/v1/subjects/:id/compliance
GET /api/compliance/v1/controls/:control_id/status
GET /api/compliance/v1/evaluations/:evaluation_id/explanation
```

Initially, this API can be read-only and internal or auditor-facing.

A response might look like:

```json
{
  "subject": {
    "type": "customer",
    "id": "canonical-42"
  },
  "as_of": "2026-09-16T22:30:00Z",
  "bundle_revision": "tenant-7-2026-09-16-0042",
  "status": "partially_compliant",
  "controls": [
    {
      "id": "CC7.2",
      "status": "compliant",
      "last_evaluated_at": "2026-09-16T22:29:58Z"
    },
    {
      "id": "CC6.3",
      "status": "unknown",
      "reason": "No attributable human actor in the legacy source event"
    }
  ]
}
```

Use `unknown` rather than silently treating missing legacy actor information as compliant. That is especially important during the strangler phase, when the new system may not yet have complete context.

The API should expose:

- Current finding status.
- Last evaluation time.
- Policy bundle revision.
- Source freshness.
- Evidence completeness.
- Whether the result is derived from legacy, canonical, or manually supplied facts.
- Explanation links for authorized users.

It should not expose executable rule definitions to ordinary customers unless that is a deliberate product decision.

## The elegant POC mode

The first implementation does not need full canonical projection for every legacy table. Start with one resource and make the pipeline complete:

```text
legacy table
  → durable change event
  → pg_notify wake-up
  → ash_strangler listener
  → canonical projection
  → audit event
  → fact extraction
  → compliance evaluation
  → read-only compliance query
```

For a first vertical slice, support:

- One legacy entity mapped to one canonical Ash resource.
- Inserts, updates, and deletes.
- One actor mapping strategy.
- One tenant mapping strategy.
- One durable source-event table.
- One cursor-based recovery worker.
- Five to ten compliance rules.
- One control with compliant, noncompliant, and unknown outcomes.
- A read-only endpoint for findings.
- Replay from a selected source-event range.

The POC should demonstrate that the same legacy event can be replayed and produce the same canonical projection, audit linkage, facts, and compliance result.

## Important correction to the current design

The current `ash_enterprise` migration plan appears to recognize that a legacy-backed resource cannot claim to have a meaningful audit trail merely because the Ash resource exists. That is correct: if writes happen in the legacy application, ordinary Ash notifications cannot see them.

The new design should therefore make the legacy projection resource explicitly different from an ordinary writable resource:

```text
Legacy resource:
  audit?: false for direct Ash writes
  read-only or projection-oriented
  source provenance required
  no claim of user action attribution by default

Projection operation:
  explicit system actor
  source event required
  produces a canonical audit event
  produces or refreshes facts
  triggers compliance evaluation
```

Once the new system becomes the writer, the resource can transition into the normal `AshEnterprise.Platform.Resource` behavior. That transition should be represented as a migration phase, not hidden as a configuration flip.

## Recommended design decision

Adopt the following rule:

> The legacy system is the source of business mutations until cutover. `ash_strangler` observes and projects those mutations. `ash_enterprise` owns the canonical audit, evidence, compliance, and query surfaces for the projected view.

That implies:

- `pg_notify` is a wake-up path only.
- A durable legacy change ledger is mandatory.
- The canonical audit log records both source action and projection action.
- Actor attribution is explicit and confidence-rated.
- System actors are used for projection and evaluation.
- Compliance rules depend on facts, not Ash actions.
- Evaluations are reevaluated from durable events and dependency metadata.
- The read-only compliance API can be deployed before anyone writes through the new system.
- Replay and reconciliation are first-class operations, not emergency tooling.

This lets the new platform begin delivering value immediately—visibility, audit, evidence, and compliance intelligence—without requiring a premature cutover or pretending that legacy writes originated inside Ash.

---

# Does ash-events simplify anything? Review ash-events-projections too. Can we avoid reimplementing the stuff re event processing by using that? Consider anyway that we can make this more elegant and simpler In any way, but especially play coast's attention to any of my ash extensions or any other ash extensions that might be able to help us and any novel elixir capabilities such as dialects or recompilation, AST type stuff etc

Yes — this is the interesting part of the design now. Reviewing `ash-project/ash_events` and your own `ash_events_projections`, a large share of the "event processing" machinery I described in the strangler answer is **already built and running in production patterns you own**. The architecture simplifies considerably.

## What AshEvents actually gives you

AshEvents is an event-architecture extension that wraps resource actions: it records create/update/destroy actions into a central event log, captures actor primary keys (including multiple actor types, e.g. `:user_id` and a string-keyed `:system_actor`), attaches arbitrary metadata via `ash_events_metadata` in changeset context, and supports replay with version-specific routing and lifecycle-hook suppression during replay. Your `ash_enterprise` already layers the tamper-evident per-tenant hash chain on top of it, which is exactly what the legacy-audit use case needs.[^5_1]

So for the strangler projection path: when a legacy change arrives, the ingester doesn't hand-write audit rows. It runs **ordinary Ash actions** on the canonical resource with `actor:` set to a `legacy_projection` system actor and `ash_events_metadata` carrying the source envelope (`source_event_id`, `source_table`, `source_user`, `transaction_id`, `actor_confidence`). AshEvents then produces the audit event, the hash-chain trigger rows you already have, actor attribution, and ordering — for free. The `Legacy.User` modules that currently set `audit?: false` stay exactly as they are, because the projection write targets the canonical resource, not the view. That's the elegant resolution of the tension flagged in your migration plan: the legacy write becomes a new-platform event without pretending the human actor executed Ash code.[^5_1]

Two AshEvents details map especially well:

- `persist_actor_primary_key :system_actor, MyApp.SystemActor, attribute_type: :string` is precisely your distinguisher between "a human did this" and "the projection engine did this," with the human preserved in metadata rather than impersonated.[^5_1]
- The advisory-lock model keys on the tenant for attribute-strategy multitenancy — consistent with your per-tenant hash-chain advisory lock, so the strangler-path writes serialize correctly alongside normal writes.[^5_1]


## What ash_events_projections gives you — and this is the big one

Your own `ash_events_projections` package is, almost literally, the compliance engine's runtime. Reading its structure: it has a `Projector` DSL for event-driven projectors with stateless/stateful handlers, a `ProjectionResource` Spark extension with `grain_fields` plus injected `:upsert_grain` and `:apply_projection_ops` actions (ops like `{:increment, field, n}` applied atomically through an `Ash.Resource.Change`), an `AttachProjection` extension exposing stats-table fields as first-class calculations on ordinary resources, a `Supervisor`/`Server` doing checkpointed serial processing, a `Checkpoint` resource tracking `last_seen_event_id` per projector, a `DeadLetter` resource keyed on `{projection_name, event_id}` with pending/failed/purge states, gap detection for bigserial ordering hazards, a `NotifyProjectors` change broadcasting `{:event_committed, log}` on commit, blue/green rebuild via `projection_name` versioning, time-travel reconstruction for a grain at a past timestamp, and mix tasks for `bootstrap`, `rebuild`, `verify`, `lag`, `dlq replay`, and `reset`. The README states the same engine powers four projectors in ScribbleVet's production setup over a shared ash_events log.

Map that onto the earlier report's compliance vocabulary and the correspondence is nearly one-to-one:


| Earlier report component | ash_events_projections equivalent |
| :-- | :-- |
| Rule dependency index + affected-rule evaluation | Projector's event-matching handlers (`grain/1` + `handle_event/1,2`) |
| Per-tenant trigger cursor / dispatch tracking | `Checkpoint.last_seen_event_id` per projector |
| Poisoned-event handling | `DeadLetter` + `dlq replay/purge` |
| Shadow evaluation of a new policy bundle | Blue/green `projection_name` versioning (`usage_v1`/`usage_v2`) |
| Historical replay / as-of evaluation for auditors | `rebuild`, `bootstrap`, and `time_travel` |
| Drift detection between derived state and log | `verify` (recompute from log, diff row-by-row) |
| Compliance status on an entity | `AttachProjection` fields as calculations on the canonical resource |
| Fast wake-up after legacy change | `NotifyProjectors` → PubSubListener fast path, checkpoint drain as the net |
| Lag/alerting for "compliance data is stale" | `mix ash_events_projections.lag` |

The definition of a compliance finding as a projection is: **grain** `[organization_id, control_id, subject_type, subject_id]`, **handlers** that translate each event into facts and run the rule engine against the denormalized grain state (arity-2 handler gets event + current row — the stateful hook you need for truth maintenance without a full rebuild), **ops** like `{:set, :status, :noncompliant}` / `{:increment, :breach_count, 1}`.

This also cleanly resolves the "no Ash action exists yet" problem: the projector consumes **events**, and the strangler ingester **emits** events through ordinary actions. The compliance pipeline never calls user-facing actions at all.

And it subsumes the `Trigger`/`TriggerCursor`/`TriggerDispatch` apparatus in your `ash_bpmn`/`ash_enterprise` process domain — `Checkpoint` is `TriggerCursor` generalized. You should consider converging: one event-consumption engine instead of two.

## What you still have to build

Be clear about the boundary — these do not come from either package:

- **Legacy-side durable capture.** AshEvents only sees Ash actions. Legacy writes still need the `legacy_change_events` ledger + `ash_strangler`'s `notify? true` pg_notify wake-up + the listener's re-read-through-Ash. That part doesn't shrink.
- **The rule IR and engine.** Rete/Wongi (or an evaluator that just pattern-matches per grain) lives inside the projector's `handle_event`. The projector is the plumbing; the engine is the semantics.
- **Control catalog governance.** Catalogs/profiles/bundle revisions from the earlier report remain Ash control-plane resources.
- **Gap semantics.** Their own `Operations.Gaps` module documents the late-committing-low-id ordering hazard in bigserial; your per-tenant advisory-lock hash chain is actually the stronger answer here — keep it and let checkpoints key off it.


## Where to simplify with DSL/AST machinery

- **Compliance rules as a Spark DSL compiling to data, not code.** You already have the template: your projection DSLs compile to resources/actions, and `ash_strangler`'s `expr.ex`/`lens.ex` shows a constrained expression layer. Author rules as Spark-declared entities whose transformer emits the **serializable IR** (never persisted quoted AST, never `Code.eval` for tenant-authored logic), with a **verifier** enforcing the fact-schema at compile time — the Cedar-style validate-before-activate pattern. Dev-authored rules get compile-time errors; tenant-authored rules get imported as IR and validated by the same verifier logic at admission.
- **Handler codegen.** A transformer's `handle_event` clauses can be generated from the rule IR's declared dependency predicates, so the projector's grain resolution and event matching are *derived* from the rule declaration rather than hand-maintained — same "declared once, derived everywhere" discipline as your manifesto.
- **New Elixir capabilities worth using, in scope order:** (1) Spark verifiers + formatters give you a documented, autocomplete-friendly compliance DSL right now — that's the real win, no exotic machinery required. (2) ETS-backed dependency index (evaluated at projector-boot from IR) rather than a DB lookup per event. (3) I'd avoid betting on the in-flight static type system (the "set-theoretic types/typing dialect" work) for the rule language — it's not a runtime-validatable contract yet. And avoid `Code.compile_string` at runtime for tenant rules; the security surface contradicts everything the audit design is for.


## Revised pipeline

```text
legacy table change
  └─ legacy_change_events ledger (trigger, transactional)
       └─ pg_notify wake-up (ash_strangler)
            └─ Listener → Ash.get re-read → IngestLegacyChange action
                 actor: :legacy_projection, metadata: source envelope
                 └─ canonical resource write  →  AshEvents event (hash-chained)
                      └─ NotifyProjectors commit broadcast
                           └─ ComplianceProjector.handle_event (facts → engine → ops)
                                └─ apply_projection_ops → findings table (grain-upserted)
                                     └─ AttachProjection exposes status on resources
                                          └─ read-only compliance API (AshJsonApi resource)
```

Checkpoint/DLQ/rebuild/verify/lag already exist. The read-only API you imagined is literally a normal AshJsonApi domain over the projection resources — findings and evidence are just rows, so policies, multitenancy, and your existing "expose this, don't expose Audit/Security" routing discipline apply unchanged.

The one deliberate duplication to keep: `ComplianceEvaluation` as an append-only evidence record *distinct* from the finding projection — a projection says "current state," the evaluation row says "what the engine decided, with which bundle and facts." Auditors need the second; the API needs the first.

Bottom line: don't reimplement event processing. AshEvents supplies log/actor/replay; your projections package supplies consumption/checkpointing/recovery/ops-verification. The genuinely new code reduces to three artifacts: the legacy ingress ledger (already largely in ash_strangler), the rule IR + evaluator, and the projector/calculation glue — plus one decision on converging the process-trigger machinery onto the same checkpoint engine.

<div align="center">⁂</div>

[^5_1]: https://github.com/ash-project/ash_events


---

# Does ash-events simplify anything? Review ash-events-projections too. Can we avoid reimplementing the stuff re event processing by using that? Consider anyway that we can make this more elegant and simpler In any way, but especially play coast's attention to any of my ash extensions or any other ash extensions that might be able to help us and any novel elixir capabilities such as dialects or recompilation, AST type stuff etc

I just covered this in my previous reply — here's the summary of that analysis, and I've re-verified the key repo facts:

## Yes, both packages remove most of the event-processing work

**`ash_events`** (ash-project) removes the need to hand-build:

- The central event log itself — it records create/update/destroy into a log table, with actor primary-key capture supporting multiple actor types (so `user_id` plus a string-keyed `:system_actor`, which is exactly your human-vs-projection-engine attribution split), arbitrary metadata via `ash_events_metadata` in changeset context, and replay with version routing and hook suppression[^6_1]
- The projection-write audit events: the legacy ingester just runs **ordinary Ash actions** on the canonical resource with `actor: :legacy_projection` and the source envelope in metadata — audit falls out of the write, instead of a bespoke audit-logging layer

**Your own `ash_events_projections`** removes the consumer-side machinery. Reviewing its source, it already has: a `Projector` DSL with stateless/stateful handlers (`grain/1`, `handle_event/1,2` — arity-2 gets event + current row, which is your truth-maintenance hook), `ProjectionResource` with `grain_fields` plus injected `:upsert_grain` and atomic `:apply_projection_ops` actions, `AttachProjection` exposing projection fields as calculations on normal resources, checkpointed serial `Server` processing, a `DeadLetter` table with replay/purge, `NotifyProjectors` commit broadcasts as the fast path with checkpoint drain as the net, blue/green projector versioning, gap detection, time-travel reconstruction, and `bootstrap`/`rebuild`/`verify`/`lag`/`dlq` mix tasks — and per the README, the engine already powers four projectors in ScribbleVet production.

The mapping to the compliance design is close to one-to-one: finding tables are grain-keyed projection resources, rule changes are projector version bumps with rebuild, "compliance as of date" for auditors is `time_travel`, and the read-only compliance API is just AshJsonApi over projection rows.

## What remains genuinely new, and where to be careful

- **Legacy ingress** (durable ledger trigger + pg_notify wake-up + listener re-read) still belongs to `ash_strangler` — `pg_notify` is at-most-once, so keep the durable table.
- **Rule IR + evaluator** (the Wongi/Rete adapter behind a behaviour) inside the projector handler.
- **One caveat:** their `Gaps` module documents the bigserial late-commit ordering hazard — your per-tenant advisory-lock hash chain is the stronger ordering primitive, so keep checkpoints keyed to it.
- **Converge the duplicate engines:** the `Trigger`/`TriggerCursor`/`TriggerDispatch` apparatus in your process domain is functionally a hand-rolled `Checkpoint` — one event-consumption engine, not two.

On DSL/AST novelty: author compliance rules as a **Spark DSL that compiles to serializable IR with a compile-time verifier** (never persist quoted AST, never `Code.eval` tenant rules), and codegen the projector's match clauses from the declared fact dependencies. The new Elixir typing work is not yet something to build a rule language on; Spark verifiers give you the validation guarantee today.

Want me to fold this revised event-processing architecture into the report as an updated section?

<div align="center">⁂</div>

[^6_1]: https://github.com/ash-project/ash_events


---

# What's the recommended structure for the ash extensions required to implement such a thing? Should I make ash rules? And then ash compliance on top of it? I think the idea of the Ledger and the durability of of event processing across the ash strangler boundary should probably be part of our strangler itself, but I guess that means introducing a dependency between ash strangler and ash events and ash projections. So potentially maybe it's an optional dependency and only if you need that feature? Let's think this through

Good question — getting the package boundaries right matters more here than any single implementation detail, because each extension you've shipped so far has a clean single purpose, and this family has three natural seams. My recommendation:

## Package layering: three packages plus optional bridges

```text
ash_rules            (semantics: what a rule IS)
ash_compliance       (governance: catalogs, bundles, findings, projectors)
ash_strangler        (ingress: legacy CDC — gains ledger, stays self-contained)
        │                      ▲
        └── optional bridges ──┘
```


### `ash_rules` — yes, make it

Rationale: "rule" is a domain-independent concept. Your roadmap already has `ash_decisions` (DMN decision tables) and the Wongi/Rete idea, and those share 80% of their infrastructure: a serializable IR, a fact schema, validation, versioning, explanation capture. If you put rules inside `ash_compliance`, you'd duplicate that infrastructure the next time the BPMN engine or a pricing domain wants rules.

Contents:

- **Spark DSL** for authoring rules (sections for `fact_schema`, `rule`, `combining`), compiling to the serializable IR, with verifiers enforcing the validate-before-activate discipline
- **Rule IR structs + JSON encoding** — data, never persisted quoted AST
- **Evaluator behaviour** — `evaluate(bundle, facts, opts)`; the Wongi adapter implements it here, as does a trivial direct-matching adapter (important for POC comparability)
- **Static analysis**: dependency extraction from declared fact schemas — this is what later feeds the projector's event matching
- **Evaluation explanation types** — the provenance graph shape, engine-agnostic

It should depend only on `ash` + `spark`. No events, no Postgres, no Wongi hard-dep (`wongi_engine` as `optional: true`).

### `ash_compliance` — on top, and it's the projector owner

Depends on `ash_rules` + `ash_events` + `ash_events_projections`. This is where the previous answer's pipeline lives:

- Control-plane resources: Catalog, Profile, RuleSetRevision, PolicyBundle (immutable, signed, per earlier report)
- The **ComplianceProjector** — an `ash_events_projections` `Projector` module that: matches events → hydrates facts → calls `ash_rules` evaluator → emits `apply_projection_ops` against finding grains
- Finding/Evidence/Evaluation resources (projection resources for live state; append-only Evaluation as the auditor-facing record)
- OSCAL import/export as mix tasks or a `DataLoader`-style boundary
- The public computations the API exposes (`AttachProjection` on the app's resources is done by the host app, not here — grain keys are domain-specific)

This keeps `ash_compliance` deployable into any Ash app that already runs ash_events, with no strangler involvement.

### The strangler durability question — the interesting one

Your instinct ("it belongs in the strangler") is right about *placement*, but I'd resist making ash_strangler depend on ash_events for it, for three reasons:

1. **Dependency direction.** ash_events is a resource/audit concern; ash_strangler is a schema-mapping library (your own package notes explain why you refused even a phoenix_pubsub dep there). A strangler user in the *proxy* or *coexistence* phase shouldn't inherit an event-log table and a supervision tree.
2. **The ledger doesn't need Ash at all.** The `legacy_change_events` table is written by a database trigger, read by a cursor worker. Making it an Ash resource couples it to the host app's repo configuration, multitenancy, and policies for no benefit — it's infrastructure, not domain.
3. **The integration point is an action, and actions belong to the host app.** The thing that consumes the ledger and creates canonical records is `IngestLegacyChange` — a host-defined Ash action, because it knows the target resource, actor mapping, and tenant derivation. Only the app can decide that actor attribution policy.

**So the elegant shape is: ash_strangler owns the durable ledger as plain infrastructure, and ships the host-app half as codegen, not as a library dep.**

Concretely:

- `phase :dual_write` (or a new `source do ledger? true end` option) generates the **ledger table + transactional trigger** in the same migration that creates the INSTEAD OF triggers today — one `mix ash_strangler.codegen` run, one reviewable diff, pg_notify becomes `{channel, "wake:<ledger_id>"}` of an already-durable row rather than the payload itself.
- A `mix ash_strangler.gen.ingester MyApp.Resource` task generates into the **host app**: the ingestion action skeleton, the actor-attribution stub (`resolve_actor/1` returning `{:ok, actor} | :unattributed`), and an Oban worker that drains the ledger by cursor. The generated code calls ash_events implicitly — because it performs ordinary actions on platform resources and AshEvents just records them.
- The fast path: today's `notify? true` + Listener stays unchanged for LiveView/cache reactivity; when `ledger? true`, the listener becomes a wake-up signal for the drain worker (idempotent cursor consumption means a missed notify is recovered by the sweep — exactly the net/fast-path pattern your ash_bpmn docs articulate).

That gives you durability *in the strangler boundary* with **zero new hex deps in either direction**. The "optional dependency" becomes an optional *generated scaffold*, which is more honest: the feature is genuinely absent until you opt in, not dormant code behind `Code.ensure_loaded?`.

Where ash_events_projections fits: nothing in this path requires it. The audit log simply fills as the ingester writes normally, and `ash_compliance`'s projector drinks from the log like any other projector. The strangler-composition line never crosses.

### Why not a separate `ash_strangler_events` bridge package?

It would work, and it's my second choice — but every concrete payload in the payload (`record_id`, `resource`, `action`, `data`) already matches AshEvents' event shape by design, and the consuming action must be host-authored regardless, so the bridge package would mostly be indirection around a 60-line Oban worker. Put that energy into the codegen task instead.

## Integration matrix

| Package | Depends on | Owns | Never does |
| :-- | :-- | :-- | :-- |
| `ash_rules` | ash, spark (+optional wongi) | Rule IR, DSL, evaluator behaviour, validation, explanations | Events, persistence, catalogs |
| `ash_compliance` | ash_rules, ash_events, ash_events_projections | Control plane, ComplianceProjector, findings, OSCAL IO | Legacy capture, user actions |
| `ash_strangler` | ash, postgrex, spark | Legacy CDC, ledger table, drain infra, gen.ingester codegen | Audit semantics, compliance, event log ownership |
| `ash_enterprise` (host) | all of the above | IngestLegacyChange action, actor resolution, tenancy mapping, API exposure | Re-derived library machinery |

## Sequencing note

`ash_rules` is the critical path and is independent of both ash_events and the strangler ledger — a POC can evaluate a hand-built fact set before any projection exists. Suggested order: `ash_rules` IR + direct-matching evaluator (2 weeks-ish POC scope) → `ash_compliance` control plane + projector → the strangler `ledger?` option + ingester codegen last, because by then the audit log the ingester feeds will be proven. If you find yourself wanting the ledger before ash_compliance ships, ship it anyway — it's independently useful (it fixes the noted listener/audit limitation even for UI-only projections).

One open naming thought: since ash_decisions exists for DMN, consider whether `ash_rules` and DMN converge on one shared `ash_logic` kernel later — a shared evaluator behaviour would let compliance bundles mix Rete-chained inference and DMN tables under one validation pass.

