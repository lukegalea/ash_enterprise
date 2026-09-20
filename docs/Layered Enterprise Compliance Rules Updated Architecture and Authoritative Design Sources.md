# Layered Enterprise Compliance Rules: Updated Architecture and Authoritative Design Sources

## Executive answer

The proposed architecture is directionally sound, but its center of gravity should change: **Ash should own the durable enterprise control plane, while Wongi should be an replaceable in-memory inference kernel behind a narrow adapter**. The most authoritative design references are not a single rule-engine blueprint. They are a combination of:

- **NIST OSCAL** for catalogs, profiles, tailoring, implementation mappings, and assessment artifacts;
- **OASIS XACML 3.0** for explicit policy-combining semantics;
- **OPA's management architecture** for versioned policy/data bundles, distribution, activation status, and decision telemetry;
- **Cedar's schema-validation model** for compile-time/static safety;
- **NIST SP 800-53A** for evidence, assessment methods, findings, and defensible compliance determinations.

Wongi is suitable for a proof of concept and potentially for production evaluation workloads after benchmarking, but it is **not** the enterprise policy architecture by itself. Its public API is a pure-Elixir, forward-chaining Rete engine using `{subject, predicate, object}` triples; it supports assertions, retractions, matching, generated facts, and automatic retraction of derived facts when their premises cease to hold. The package is currently version 0.9.20, requires Elixir 1.15 or later, has a small dependency surface, and is MIT-licensed.

## Authoritative reference model

No single standard exactly describes “global rules + tenant overrides + Ash + a Rete engine.” The defensible design is a synthesis in which each source governs a different concern.

| Concern | Authoritative source | Design implication |
|---|---|---|
| Control catalogs and reusable standards | NIST OSCAL Catalog and Profile concepts | Store the global rule library as immutable/versioned catalogs; build tenant-effective baselines by selection, parameterization, and tailoring, not by mutating canonical rules.[^1] |
| Implementations and mappings | NIST OSCAL Component Definition | Model mappings from controls to software, services, policies, processes, and procedures as first-class versioned records; component definitions describe reusable possible implementations, not proof that an implementation is operating effectively.[^2][^3] |
| Conflict and override behavior | OASIS XACML 3.0 | Give every rule set an explicit combining algorithm instead of relying on incidental evaluation order. XACML standardizes deny-overrides, permit-overrides, first-applicable, and only-one-applicable semantics.[^4][^5] |
| Packaging and distribution | Open Policy Agent management architecture | Compile a complete immutable “effective policy bundle” per tenant and revision. OPA bundles combine policy and data, carry a revision in a manifest, and expose activation/status and decision-log patterns.[^6][^7][^8][^9] |
| Policy/schema safety | Cedar | Validate policies separately before evaluation against a schema defining valid entity types, attributes, relationships, actions, and request context.[^10][^11][^12][^13] |
| Evidence and findings | NIST SP 800-53A | Separate automated rule evaluation from formal assessment. A defensible assessment applies methods such as examine, interview, and test to defined assessment objects and produces findings from evidence.[^14][^15] |

### Primary recommendation

Adopt **OSCAL's conceptual object model**, not necessarily OSCAL's wire format everywhere. Internally, Ash resources can be ergonomic and relational; import/export boundaries should preserve OSCAL identifiers, parameters, provenance, and revision lineage. In particular:

- A `ControlCatalog` corresponds to an authoritative/global body of controls.
- A `ControlProfile` selects and tailors controls for a jurisdiction, business unit, product, or tenant.
- A `ControlImplementation` maps controls to components and executable checks.
- An `AssessmentPlan` declares what will be evaluated and which evidence is required.
- An `AssessmentResult` records observations, findings, evidence references, and the exact policy bundle revision used.

OSCAL profiles are especially relevant to the original hierarchy question: they define operations applied to one or more catalogs to select and tailor a baseline.[^1] That is cleaner than copying global rules into every tenant and then attempting to reconcile divergence.

## Revised architecture

### Control plane

The control plane is authoritative, durable, transactional, and tenant-aware. It should use Ash resources backed by PostgreSQL:

- `Catalog`: stable identity for a source such as SOC 2, ISO 27001, or an internal standard.
- `CatalogVersion`: immutable imported/released revision.
- `Control`: stable semantic identity, independent of wording revisions.
- `ControlRevision`: versioned text, parameters, source citations, and metadata.
- `Profile`: a reusable selection/tailoring overlay.
- `ProfileRevision`: immutable set of additions, removals, parameter assignments, and refinements.
- `TenantPolicySet`: tenant attachment to one or more catalog/profile revisions.
- `PolicyOverride`: a scoped patch, exception, or local rule, never an in-place mutation of a global rule.
- `RuleDefinition`: normalized, typed rule intermediate representation.
- `RuleSetRevision`: immutable executable release with status `draft`, `validated`, `approved`, `active`, `retired`, or `revoked`.
- `ControlMapping`: versioned many-to-many mapping between rules, controls, components, evidence requirements, and remediation playbooks.
- `EvaluationRun`: one execution against one tenant, input snapshot, and bundle revision.
- `Finding`: a result derived from one or more rule matches.
- `EvidenceArtifact`: immutable reference to a source artifact, hash, collection method, time, and retention classification.
- `DecisionTrace`: compact explanation/provenance graph for a decision.

Do **not** use tenant override rows as if they were final executable policy. Publish a resolved artifact:

`global catalog revisions + profiles + tenant patches + parameter values -> validated effective bundle`

The effective bundle gets a content hash, monotonically identifiable revision, compiler version, schema version, activation time, and signature. Runtime evaluators only consume validated bundles.

### Data plane

The data plane evaluates immutable bundles against an immutable input snapshot. A tenant-scoped evaluator process may cache a compiled Wongi network, but that process is an optimization, not the source of truth.

Recommended boundaries:

1. `PolicyCompiler` resolves catalog/profile/override layers into a typed intermediate representation.
2. `PolicyValidator` checks schema, references, variable binding, prohibited recursion or side effects, conflict rules, and determinism constraints.
3. `PolicyBundleBuilder` emits a content-addressed bundle.
4. `Evaluator` exposes `evaluate(bundle, facts, options)` and returns findings plus provenance.
5. `WongiAdapter` translates the internal rule IR to Wongi triples, matchers, and productions.
6. `ResultPersister` records the decision and trace transactionally without allowing rule actions to perform arbitrary database mutations.

This boundary avoids making the domain model dependent on Wongi's triple representation. It also allows a later OPA, Cedar, Datalog, SQL, or custom evaluator without rewriting resource and API contracts.

## Layering semantics

The original phrase “tenant rules may override or extend global rules” is too ambiguous for an auditable system. “Override” needs a finite vocabulary and deterministic precedence.

### Supported operations

- `include`: select a global control or rule revision.
- `exclude`: remove it only where governance policy permits.
- `parameterize`: bind an approved parameter, such as retention duration.
- `refine`: narrow applicability or strengthen a requirement.
- `supplement`: add tenant-local logic without modifying the source rule.
- `replace`: supersede a rule only with explicit governance approval and a reason.
- `waive`: suspend enforcement for a bounded time and scope, with approver and compensating controls.

### Precedence

Use a fixed order such as:

1. Non-waivable regulatory/global prohibitions.
2. Global mandatory rules.
3. Jurisdiction/profile refinements.
4. Tenant strengthening rules.
5. Approved tenant replacements or waivers.
6. Tenant supplements.

Within each level, require an explicit combining algorithm. XACML demonstrates why this belongs in the model: a policy set's result must be computed by a named algorithm such as deny-overrides, permit-overrides, first-applicable, or only-one-applicable.[^4][^16] For compliance, the safe default is typically **deny/noncompliant overrides**, with a distinct `unknown` or `indeterminate` result when required data is absent or evaluation fails.

### Decision lattice

A Boolean result is insufficient. Use at least:

- `compliant`
- `noncompliant`
- `not_applicable`
- `unknown`
- `error`

`unknown` means evidence or required facts were unavailable; `error` means the rule could not be evaluated. Neither should silently collapse to compliant. XACML's treatment of `Indeterminate` and `NotApplicable` is a useful semantic precedent, even if the project does not implement XACML syntax.[^4][^17]

## Wongi suitability

### What Wongi does well

Wongi's fact model maps naturally to graph-like compliance assertions. Its public interface represents all knowledge as triples, supports variable binding across matcher sequences, permits generated facts, and automatically retracts generated facts when supporting conditions disappear. Those are useful properties for derived attributes, transitive relationships, eligibility inference, and incremental reevaluation.

The project is active as of September 2026, including recent dependency maintenance and type-warning fixes, and the canonical repository is the upstream `ulfurinn/wongi-engine-elixir` project. Its MIT license permits use, modification, sublicensing, and distribution subject to preservation of the notice.

### What Wongi does not provide

The documented public surface is an inference kernel: create an engine, compile rules, assert/retract/select facts, and inspect production tokens. The repository structure exposes Rete, compiler, DSL, matcher/filter, action, aggregate, token, WME, and index modules, but no documented enterprise control-plane facilities for durable policy versions, approval workflows, signed bundles, tenant isolation, evidence retention, or decision-log governance.

Therefore:

- Use Wongi only behind `Evaluator` and `WongiAdapter` behaviours.
- Do not expose Wongi rule references as durable business identifiers; they are runtime references.
- Do not persist raw Wongi engine state as the canonical policy representation.
- Do not allow tenant-authored Elixir closures or arbitrary `assign`/action code in production policy.
- Do not use Wongi-generated side effects for durable remediation. Emit typed findings/events and process them separately.
- Pin the package version, add contract tests, and maintain an internal compatibility shim.

### Production gate

Wongi is **sufficient for a POC** if the POC proves semantic correctness, explanation capture, tenant isolation, and reload behavior—not merely that a few rules fire. Production use should require:

- Benchmarks with realistic fact counts, rule counts, join cardinality, and tenant concurrency.
- Memory profiling for cached per-tenant networks.
- Cancellation and wall-clock limits.
- Determinism tests across repeated runs.
- Golden tests comparing expected findings and traces.
- Recovery tests for engine process crashes and bundle activation failures.
- A fuzz/property-test suite for assertion/retraction consistency.
- A fallback path to rebuild evaluators entirely from bundle plus input snapshot.

## DSL guidance

### Do not start with a custom surface DSL

Start with a typed, serializable rule IR. A pleasant Elixir DSL can compile into that IR, but the stored contract should not be quoted Elixir AST or executable anonymous functions. A minimal IR needs:

- Stable rule ID and revision.
- Applicability/target expression.
- Typed predicates and variables.
- Required fact declarations.
- Outcome and severity.
- Combining metadata.
- Control mappings.
- Evidence requirements.
- Human-readable message template.
- Remediation reference.
- Provenance and source citations.

### Ash/Spark integration

Ash's extension stack is a good authoring layer. Spark is explicitly intended for building extensible, documented Elixir DSLs and powers Ash's DSLs.[^18][^19] Ash extensions can define DSL sections, run serial transformers over DSL state, validate or modify resource definitions, and expose runtime introspection.[^20]

Use a `Spark.Dsl.Extension` for compile-time, developer-authored rules. Use Ash resources and actions for customer-authored or dynamically imported rules. Compiled application modules cannot serve as the only tenant rule store because tenant policy changes must not require a deployment.

### Validation

Follow Cedar's split between validation and evaluation. Cedar validates policy against a schema defining valid entity types, attributes, parent-child relationships, actions, principals, resources, and context; validation is deliberately a separate API run before authorization.[^10][^12] Apply the same pattern to compliance rules:

- Validate every field and predicate against a `FactSchema`.
- Type-check operators and function arguments.
- Reject unknown attributes and unsafe optional-field access.
- Require declared missing-data behavior.
- Validate that referenced controls and mappings exist in the pinned catalog revision.
- Revalidate all dependent bundles after a schema change.

## Multitenancy and lifecycle

### Isolation model

Prefer attribute-based tenant partitioning in PostgreSQL for the control plane, reinforced by database row-level security where practical. Treat `tenant_id` as part of every unique key for tenant-owned resources, and never infer tenant identity from request payload alone.

For Wongi evaluators:

- Never mix facts from multiple tenants in one engine instance.
- Name/cache processes by `{tenant_id, bundle_revision}` rather than tenant alone.
- Enforce maximum active revisions and idle eviction.
- Make bundle loading atomic: build and validate a new evaluator, then switch a pointer.
- Keep old revisions available for replay until retention rules allow deletion.

### Versioning

A mutable `version` integer on a rule row is not enough. Use immutable revisions and effective dating:

- Stable entity ID: `rule_id`.
- Immutable revision ID: `rule_revision_id`.
- Semantic version or sequence for people.
- Content hash for integrity and deduplication.
- `valid_from`/`valid_to` for regulatory applicability.
- `published_at`/`activated_at` for operational rollout.
- `supersedes_revision_id` for lineage.
- `source_uri`, source version, and source hash.

OPA's bundle format provides a useful operational precedent: bundles contain policy and data, may include a manifest, and can identify a revision; agents report the last successfully activated revision.[^6][^7] Adopt equivalent activation and rollback observability even if the binary bundle format is custom.

### Rollout

Support:

- Draft and approval workflow.
- Staged validation in a sandbox tenant.
- Shadow evaluation against historical snapshots.
- Canary activation for selected tenants.
- Scheduled activation and expiry.
- Instant rollback to a previous signed bundle.
- Revocation for unsafe rule revisions.

## API design

Do not make CRUD resources the primary external contract. Expose lifecycle and evaluation operations:

- `POST /policy-bundles:compile`
- `POST /policy-bundles/{revision}:validate`
- `POST /policy-bundles/{revision}:approve`
- `POST /policy-bundles/{revision}:activate`
- `POST /policy-bundles/{revision}:rollback`
- `POST /evaluations`
- `GET /evaluations/{id}`
- `GET /evaluations/{id}/explanation`
- `POST /evaluations:simulate`
- `POST /controls:import-oscal`
- `GET /controls:export-oscal`

Every evaluation request should specify or resolve exactly one tenant, bundle revision, fact-schema revision, and `as_of` time. Every response should return them, plus a decision ID, content hash, outcome, findings, missing facts, and trace reference.

Idempotency is required for evaluation submission and bundle activation. The same idempotency key with the same request hash should return the original result; the same key with a different hash should fail.

## Audit and evidence

An audit log is not the same as an explanation, and neither is the same as evidence.

- **Audit event:** who changed, approved, activated, or evaluated what and when.
- **Decision trace:** which rules and facts produced the result.
- **Evidence artifact:** the underlying document, API response, test output, configuration snapshot, interview record, or observation supporting an assessment.
- **Finding:** the assessor/system's determination associated with controls and evidence.

NIST SP 800-53A explicitly frames assessment as the application of methods to assessment objects to gather evidence and produce findings; its methods include examine, interview, and test.[^14][^15] This means an automated Wongi result should normally be classified as one evidence-producing mechanism or automated test result, not as the whole compliance judgment.

Store evidence immutably with:

- Hash and media type.
- Collector identity and method.
- Source system and source timestamp.
- Tenant, asset, control, and evaluation links.
- Classification and retention policy.
- Chain-of-custody events.
- Redaction status.
- Encryption/key version.

Use append-only audit records and hash chaining or signed batch manifests where tamper evidence matters. Avoid putting sensitive payloads in general application logs; log IDs and hashes, and enforce purpose-bound access to the evidence store.

## Explanation design

Rete tokens alone are not a sufficient customer explanation. Capture a domain-level provenance graph during evaluation:

- Rule revision and source.
- Control mappings.
- Input facts consumed, with source references.
- Derived facts and the rule that generated each one.
- Override/profile operations applied.
- Missing facts and failed predicates.
- Combining algorithm and competing outcomes.
- Final finding and remediation link.

Wongi already tracks the rule responsible for generated facts and retracts them with their support, which provides a useful foundation for truth-maintenance behavior. The adapter should translate that runtime provenance into stable domain identifiers rather than expose engine-internal references.

## Side effects and remediation

Rules should be pure with respect to durable state. A rule may derive a finding, obligation, recommended remediation, notification intent, or workflow command, but should not directly update customer records, send email, or close a finding.

Recommended sequence:

1. Evaluate pure policy.
2. Persist result, trace, and outbox events in one transaction.
3. Dispatch events asynchronously.
4. Run remediation through authorized Ash actions or workflows.
5. Record completion as new facts/evidence.
6. Reevaluate if required.

This makes retries and replay safe. It also prevents an evaluator crash from leaving half-applied remediation.

## Alternatives

| Option | Best fit | Strengths | Limitations |
|---|---|---|---|
| Wongi/Rete | Incremental inference over graph-like changing facts | Native Elixir, triples, joins, generated facts, automatic retraction. | Enterprise lifecycle, schema validation, persistence, and audit must be built around it. |
| OPA/Rego | General policy-as-code and centrally distributed policy/data | Mature bundle revisions, status, discovery, and decision-log architecture; declarative rules over structured data.[^6][^21][^8][^9] | Separate runtime/operational stack; not a forward-chaining truth-maintenance engine. |
| Cedar | Authorization-shaped decisions with strong schema validation | Clear principal/action/resource/context model and robust pre-evaluation validation.[^10][^11][^13] | Less natural for broad compliance inference and evidence workflows. |
| XACML | Standards-driven authorization and explicit combining semantics | Formal policy sets and standardized conflict-combining algorithms.[^4][^5] | Heavy model and syntax; use as a semantic reference unless interoperability requires it. |
| SQL/Ash expressions | Simple checks close to relational data | Operational simplicity, query pushdown, aggregates and calculations in Ash.[^22][^23] | Poor fit for deep chained inference and explanation graphs. |

Recommendation: retain Wongi for the POC, but implement one SQL/Ash evaluator for simple predicates behind the same behaviour. This tests whether Rete is actually needed and prevents every compliance check from being forced into triples.

## POC scope

The proof of concept should answer architectural questions, not showcase a broad rules catalog.

### Vertical slice

Build one global catalog, one profile, two tenants, and approximately 15-25 rules covering:

- Simple attribute checks.
- Multi-fact joins.
- Negation/missing evidence.
- Derived facts.
- One aggregate.
- A global mandatory rule.
- A tenant strengthening rule.
- An approved bounded waiver.
- A conflict resolved by explicit combining semantics.
- A rule change requiring historical replay.

### Acceptance criteria

- Replaying the same bundle and input snapshot produces the same result and trace.
- A tenant override cannot affect another tenant.
- Every finding identifies exact rule, control, bundle, fact-schema, and evidence revisions.
- Missing evidence yields `unknown`, not `compliant`.
- A new bundle activates atomically and rollback works.
- Engine crash recovery rebuilds state from durable artifacts.
- Shadow evaluation shows the exact delta between revisions.
- No policy-authored code can perform arbitrary I/O.
- Benchmarks meet agreed p95 latency and memory budgets under representative concurrency.

## Phased roadmap

### Phase 0: semantics

- Define outcome lattice and combining algorithms.
- Define catalog/profile/override operations.
- Define rule IR and fact schema.
- Define stable IDs and immutable revision model.
- Decide which OSCAL artifacts to import/export.

### Phase 1: POC

- Implement Ash resources for catalogs, revisions, profiles, tenant attachments, bundles, evaluations, findings, and evidence references.
- Build `Evaluator` and `WongiAdapter` behaviours.
- Compile a constrained DSL/IR to Wongi.
- Implement deterministic traces and golden tests.
- Benchmark Wongi against direct Ash/SQL checks.

### Phase 2: governance

- Add approvals, signatures, activation, rollback, and revocation.
- Add static schema validation and dependency analysis.
- Add sandbox and historical simulation.
- Add append-only audit and outbox-driven remediation.

### Phase 3: interoperability

- Add OSCAL catalog/profile/component import and export.
- Add assessment-plan/result interchange where customers require it.
- Add mapping/version-management workflows for framework revisions.

### Phase 4: scale

- Add tenant evaluator pools, eviction, bounded execution, and distributed bundle caches.
- Add high-cardinality performance tests and chaos recovery.
- Consider a separate policy runtime only if operational or interoperability needs justify it.

## Answers to the remaining questions

### Is a custom DSL justified?

Yes, but only as an authoring convenience over a typed, serializable IR. Spark/Ash is the right place for a compile-time Elixir DSL because Spark supplies extensibility, documentation, and tooling.[^18][^19] Dynamic tenant rules should be data validated against the same schema, not newly compiled Elixir modules.

### How should global and tenant rules interact?

Through catalog/profile/patch compilation into immutable effective bundles. Never resolve inheritance ad hoc during each evaluation. Use explicit operations and combining algorithms, with mandatory global constraints marked non-waivable.

### How should rules be versioned?

Stable logical ID plus immutable revision ID, content hash, source lineage, effective dates, approval state, and signed bundle revision. Record the exact bundle and schema revision in every evaluation.

### How should auditability work?

Use four linked records: audit event, decision trace, evidence artifact, and finding. An append-only event log establishes lifecycle accountability; a provenance graph explains logic; evidence supports the assertion; the finding states the determination.

### How should side effects work?

Do not execute external side effects inside rules. Emit typed intents through a transactional outbox, authorize remediation through Ash actions/workflows, and feed resulting state back as new facts or evidence.

### How should the API be shaped?

Around compile, validate, approve, activate, simulate, evaluate, explain, rollback, import, and export—not merely CRUD. Require tenant, revision, idempotency, and `as_of` semantics.

### Is Wongi mature enough?

It is actively maintained, permissively licensed, and technically credible as a small Rete kernel, but its current 0.9.20 version and deliberately narrow public surface justify treating it as a swappable dependency and requiring production benchmarks and failure testing.

## Final design decision

Proceed with the POC under these constraints:

1. **OSCAL-inspired control plane** for catalogs, profiles, implementations, and assessment exchange.
2. **XACML-inspired explicit combining semantics** for conflicts and overrides.
3. **OPA-inspired immutable bundles and activation telemetry** for runtime distribution.
4. **Cedar-inspired schema validation before activation** for safety.
5. **SP 800-53A-inspired evidence and findings model** for defensibility.
6. **Wongi behind an evaluator adapter**, never as the durable source of truth.
7. **Ash resources/actions for governance, storage, authorization, tenancy, APIs, and remediation workflows**.

That design keeps the native-Elixir advantage while avoiding lock-in to the least mature layer of the stack.

---

## References

1. [OSCAL Control Layer: Profile Model - NIST Pages](https://pages.nist.gov/OSCAL/learn/concepts/layer/control/profile/) - OSCAL profiles define a set of operations that are to be performed on one or more control catalogs t...

2. [Creating a Component Definition - NIST Pages](https://pages.nist.gov/OSCAL/learn/tutorials/implementation/simple-component-definition/) - An OSCAL component definition contains a collection of components. Each component in a component def...

3. [OSCAL Component Definition Model v1.1.2 JSON ... - NIST Pages](https://pages.nist.gov/OSCAL-Reference/models/v1.1.2/component-definition/json-definitions/) - The OSCAL Component Definition Model can be used to describe the implementation of controls in a com...

4. [eXtensible Access Control Markup Language (XACML) Version 3.0](https://docs.oasis-open.org/xacml/3.0/xacml-3.0-core-spec-os-en.html) - The result of this combining algorithm ensures that one and only one policy or policy set is applica...

5. [eXtensible Access Control Markup Language (XACML) Version 3.0 ...](https://docs.oasis-open.org/xacml/3.0/xacml-3.0-core-spec-en.html) - Lists Errata for the OASIS Standard eXtensible Access Control Markup Language (XACML) Version 3.0.

6. [Bundles - Open Policy Agent](https://openpolicyagent.org/docs/management-bundles) - This should help the Bundle Service to send the correct revision of the bundle to OPA. What happens ...

7. [Status | Open Policy Agent](https://openpolicyagent.org/docs/management-status) - OPA can periodically report status updates. The updates contain status information for OPA itself as...

8. [Discovery | Open Policy Agent](https://openpolicyagent.org/docs/management-discovery) - Discovery. OPA can be configured to download bundles of policy and data, report status, and upload d...

9. [OPA Management APIs and Architecture | Open Policy Agent](https://www.openpolicyagent.org/docs/management-introduction) - OPA exposes a set of APIs that enable unified, logically centralized policy

10. [Cedar policy validation against schema](https://docs.cedarpolicy.com/policies/validation.html) - To validate a policy, Cedar needs information about the application. It needs to know the correct na...

11. [Cedar Docs - Cedar Policy](https://docs.cedarpolicy.com/) - Cedar doesn't use the schema when evaluating an authorization request. Instead, it uses the schema t...

12. [Schema overview | Cedar Policy Language Reference Guide](https://docs.cedarpolicy.com/schema/schema.html) - After you define a schema, you can ask Cedar to validate your policies against it to ensure that you...

13. [Security | Cedar Policy Language Reference Guide](https://docs.cedarpolicy.com/other/security.html) - Cedar security

14. [SP 800-53A Rev. 5, Assessing Security and Privacy Controls in ...](https://csrc.nist.gov/pubs/sp/800/53/a/r5/final) - This publication provides a methodology and set of procedures for conducting assessments of security...

15. [nist.sp.800-53ar4.pdf](https://nvlpubs.nist.gov/nistpubs/specialpublications/nist.sp.800-53ar4.pdf)

16. [eXtensible Access Control Markup Language (XACML ...](https://docs.oasis-open.org/xacml/3.0/xacml-3.0-core-spec-csprd04-en.html)

17. [XACML 3.0 Additional Combining Algorithms Profile Version 1.0](https://docs.oasis-open.org/xacml/xacml-3.0-combalgs/v1.0/csprd03/xacml-3.0-combalgs-v1.0-csprd03.html) - The on permit deny second combining algorithm is primarily intended for those cases where it would b...

18. [ash-project/spark: Tooling for building DSLs in Elixir](https://github.com/ash-project/spark) - Tooling for building DSLs in Elixir. Contribute to ash-project/spark development by creating an acco...

19. [Get Started With Spark — spark v0.2.4](https://hexdocs.pm/spark/0.2.4/get-started-with-spark.html)

20. [ash/documentation/topics/advanced/writing-extensions.md at main · ash-project/ash](https://github.com/ash-project/ash/blob/main/documentation/topics/advanced/writing-extensions.md) - A declarative, extensible framework for building Elixir applications. - ash-project/ash

21. [Policy Language - Open Policy Agent](https://openpolicyagent.org/docs/policy-language) - Generating Objects Rules that define objects are very similar to rules that define sets. Note that o...

22. [Expressions — ash v1.47.8](https://hexdocs.pm/ash/1.47.8/expressions.html)

23. [ash/documentation/topics/resources/aggregates.md at main · ash-project/ash](https://github.com/ash-project/ash/blob/main/documentation/topics/resources/aggregates.md) - A declarative, extensible framework for building Elixir applications. - ash-project/ash

