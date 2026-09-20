# The provenance envelope

| | |
|---|---|
| **Status** | Design — for review |
| **Lane** | G (enterprise verification) |
| **Work item** | Plane project AST |
| **Touches** | `AshEnterprise.Platform`, `AshEnterprise.Audit`, `AshEnterprise.Process`, `AshEnterprise.Decisions`, `ash_bpmn`, `ash_decisions` |
| **Companions** | [`decision-validation.md`](decision-validation.md), [`feel-type-integration.md`](feel-type-integration.md) |

---

## 1. Problem

Four subsystems each record provenance, correctly, in four incompatible shapes.

| Subsystem | Carrier | Shape |
|---|---|---|
| Audit | `AshEnterprise.Audit.EventLog` | `metadata["correlation_id"]`, `metadata["depth"]`, `metadata["system_actor"]`, `metadata["impersonator_id"]` — a JSON map, stamped by `AshEnterprise.Platform.Correlation.audit_metadata/1` |
| Process | `AshEnterprise.Bpmn.Instance` | a `correlation_id` **string** attribute, plus `started_by_id`, `parent_instance_id`, `trigger_depth` |
| Decisions | `AshEnterprise.Decisions.Evaluation` | a `correlation_id` **string** attribute, plus `definition_key`/`definition_version` denormalized onto the row |
| Tracing | OpenTelemetry via `Ash.Tracer` → `OpentelemetryAsh` | span/trace ids in process context, exported only when `OTEL_EXPORTER_OTLP_ENDPOINT` is set |

They agree on the *word* `correlation_id` and nothing else. The audit log's lives in JSON; the
other two are columns; OTel's trace id is not written down anywhere at all. And the compliance
log (`AshEnterprise.Compliance.EventLog`) is a fifth shape again, with its own moduledoc
explaining why it could not reuse the audit one.

The consequence is that the question this platform exists to answer — *show me everything
behind this outcome* — is a three-way join across three conventions, and the join key is
missing from at least one leg of any real trail. A decision evaluated inside an Oban-dispatched
BPMN node is the ordinary case, and it is exactly where the key is lost:
`AshEnterprise.Platform.Correlation` is process-dictionary state, its own moduledoc says the
id does not cross process boundaries, and `AshEnterprise.Process.DecisionResolver` reaches for
`ctx.instance.correlation_id` precisely because the ambient one is gone by then.

Two further gaps that are not about joins:

**Nothing records what was decided *against*.** An evaluation row carries `inputs` and
`outputs` as JSON. That is evidence, and it is also a pile of customer data in a table with no
retention policy — a collision the audit log's moduledoc already names against
`docs/manifesto/07-what-we-do-not-have.md`. There is no artefact that proves *which inputs*
produced *which outputs* without holding the inputs.

**Nothing records which version of the logic ran, for logic that has no version.** DMN and
BPMN definitions are versioned integers. An Ash action is not versioned at all, so "the
approval action changed last Tuesday" is invisible in an audit trail that names the action but
not its shape.

---

## 2. Design

### 2.1 One struct

```elixir
defmodule AshEnterprise.Provenance.Envelope do
  @moduledoc """
  What ran, under whose authority, over what, and with what result — as identifiers
  and digests, never as values.
  """

  defstruct [
    # ── what ran ────────────────────────────────────────────────────────────
    :semantic_id,          # String.t()  — §2.2
    :definition_version,   # String.t()  — §2.3

    # ── on whose behalf ─────────────────────────────────────────────────────
    :tenant_id,            # Ash.UUID.t() | nil
    :actor_id,             # Ash.UUID.t() | nil
    :system_actor,         # String.t() | nil — set exactly when actor_id is nil
    :impersonator_id,      # Ash.UUID.t() | nil

    # ── over what, to what effect ───────────────────────────────────────────
    :input_digest,         # String.t() | nil — §2.4
    :output_digest,        # String.t() | nil — §2.4
    :redaction_digest,     # String.t() | nil — §2.4
    :dropped_fields,       # [String.t()]     — §2.4

    # ── what the run consulted ──────────────────────────────────────────────
    matched_rule_ids: [],     # [String.t()]  — from decision-validation.md §3
    policy_decision_ids: [],  # [String.t()]  — §2.5
    evidence_ids: [],         # [String.t()]  — §2.6

    # ── how it joins ────────────────────────────────────────────────────────
    :correlation_id,       # Ash.UUID.t()  — the existing one, unchanged
    :process_instance_id,  # Ash.UUID.t() | nil
    :trace_id,             # String.t() | nil — W3C trace-id, 32 lower hex
    :span_id,              # String.t() | nil — W3C span-id, 16 lower hex
    depth: 0               # integer — from Correlation.depth/0
  ]
end
```

`correlation_id` is kept, not replaced. It already works, it is already indexed on three
tables, and replacing a working join key as part of adding a richer one is how you get a
migration that nobody can verify. The envelope *carries* it.

### 2.2 `semantic_id` — reuse the manifest's grammar

The semantic-manifest RFC (`docs/rfc/semantic-manifest-v0.md` §4.3) already defines a symbol
id grammar for exactly this job: structural, human-readable, diffable, stable across recompiles,
ordinal fallback where there is no name, and explicitly *not* content-hashed because "an
identifier that appears in editor state, agent transcripts, and cross-manifest relations"
must not churn on every edit.

Those are the same requirements an envelope has, so the envelope uses the same grammar rather
than inventing a second one:

```
<scheme>:<version>:<root>#<path>/<name>[:<discriminator>]
```

| Unit of execution | `semantic_id` |
|---|---|
| Ash action | `ash:v0:AshEnterprise.Security.AccessRequest#actions/record_risk` — the RFC's id, unmodified |
| Generic/code-interface call | `ash:v0:AshEnterprise.Decisions#code_interface/evaluate/3` — the RFC's domain-rooted rule |
| DMN decision | `dmn:v0:kyc_risk_band#decisions/Decision_risk` |
| BPMN node | `bpmn:v0:access_request_approval#nodes/Task_grant_role` |
| Policy | `ash:v0:AshEnterprise.Security.AccessRequest#policies/0` — ordinal, per RFC §4.3 |

The three rules the RFC attaches to its ids apply verbatim and are not restated here: ids are
structural; unnamed things fall back to declaration ordinal and carry `id_stability: "ordinal"`;
and a consumer that does not recognize a scheme treats it as opaque rather than erroring
(RFC §6.2).

The `dmn:` and `bpmn:` schemes are net-new and are the one place this design extends the RFC
rather than consuming it. They are proposed *back* to the RFC as additional schemes rather than
maintained separately — the alternative is two id grammars that are 95% the same, which is the
failure mode the RFC's own revision 2 exists to correct.

### 2.3 `definition_version`

Three sources, all rendered as a string so one column holds all of them:

- **DMN / BPMN:** `"3"` — the integer `version` from
  `AshDecisions.Resources.Definition` / `AshBpmn.Resources.Definition`, which is already
  denormalized onto evidence rows for the reason that resource's moduledoc gives: an evidence
  row that can only be understood by joining to a mutable table is evidence with a dependency.
  For a tenant fork, `"t3<-p5"` records what `AshEnterprise.Process.Binding.forked_from_version`
  holds, because a fork's version 3 and the platform's version 3 are different documents.
- **Ash action:** `"sha256:a3f19c…"` — the action symbol's `hashes.content` from the semantic
  manifest (RFC §4.4), which is defined as "the whole symbol minus hashes and minus spans" and
  therefore answers *did anything semantic change?* while ignoring a declaration moving down a
  file. This is the version number an Ash action does not otherwise have.
- **Unknown:** `nil`. Never a guess.

Making Ash actions versionable by manifest digest is the largest single win here and it costs
nothing beyond emitting the manifest: "which shape of `record_risk` ran" becomes answerable
for every historical row, and a diff of two digests points at the commit.

### 2.4 Digest rules — no sensitive values, by default or otherwise

**Normative: the envelope holds no field values.** Not "no sensitive values" with an allowlist
— no values. An envelope is safe to replicate, index, export and retain indefinitely precisely
because there is nothing in it to leak, and an allowlist is a thing that drifts.

```elixir
@spec digest(term()) :: String.t()
# "sha256:" <> Base.encode16(hash, case: :lower) |> binary_part(0, 39)
```

Format and truncation are the RFC's (§4.4): `sha256:` prefix, lower hex, truncated to 32 hex
characters — 128 bits, collision-safe at project scale and short enough to read in a diff.
The canonical JSON form is the RFC's too (§7.2). One implementation, `AshEnterprise.Provenance.Digest`,
shared by both documents, because two implementations of one canonical form is how a verifier
ends up disagreeing with reality about nulls and key order —
`AshEnterprise.Audit.Chain`'s moduledoc makes exactly this argument about recomputing the
audit digest in SQL rather than Elixir, and it applies here unchanged.

Four rules:

1. **Digest the normalized form, not the accepted form.** The RFC's accepted/normalized split
   (§5.1–5.3) is the right line: `%{"amount" => "100"}` and `%{amount: Decimal.new(100)}` are
   the same logical input and must digest identically, or the digest answers a question about
   JSON encoding rather than about the decision. For decisions this means digesting the output
   of `AshDecisions.Feel.to_feel_value/2` — which is the cast boundary, and is where an integer
   becomes a `Decimal`. For actions it means digesting the changeset's cast attributes and
   arguments, not the raw params.

2. **Sensitive fields are excluded by name, and the exclusion is itself digested.**
   `sensitive?: true` attributes, `Ash.ForbiddenField` values and anything a resource marks
   through `AshCloak` are removed before hashing. The sorted list of removed field *names* (not
   values) is hashed into `redaction_digest`. Two envelopes can then be compared for "were the
   same things withheld?", which is the question that matters when a decision went differently
   for two apparently identical cases.

3. **Dropped fields are recorded, not silently absent.** `to_feel_value/2` drops
   `%Ash.NotLoaded{}` and `%Ash.ForbiddenField{}` rather than nilling them, deliberately —
   its moduledoc explains that nilling "would let a hidden value decide a case". Dropping is
   correct and invisible: a dropped key is a missing path is `null` is *this rule did not
   match*. `dropped_fields` names them, so the invisible becomes a column. This is the same
   failure [`decision-validation.md`](decision-validation.md) §4 surfaces from the explanation
   side; here it is captured on every run rather than on request.

4. **A digest of nothing is `nil`, never a digest of `%{}`.** `sha256(canonical(%{}))` is a
   real hash of a real empty map and would make "no inputs" indistinguishable from "inputs not
   captured". Envelopes from a subsystem that has not been wired yet must be distinguishable
   from envelopes over genuinely empty input.

**Opting in to payloads.** Some evidence genuinely requires the values — a `UNIQUE` violation
is not debuggable from a digest. `AshDecisions.Resources.Evaluation` already stores `inputs`
and `outputs`, and this design does not remove them. It separates them: the *envelope* is
digest-only and retained indefinitely; the *payload* lives on the domain row it belongs to and
is governed by that row's retention (§2.7). The digest is what proves the retained envelope
and the possibly-deleted payload belong together.

### 2.5 `policy_decision_ids` — the least-grounded field, and why it is still here

Ash policies produce an authorization outcome, not an identifier. There is nothing to record
today.

The proposal: a policy decision id is the policy's RFC-grammar symbol id plus its outcome:

```
ash:v0:AshEnterprise.Security.AccessRequest#policies/0:authorized
ash:v0:AshEnterprise.Security.AccessRequest#policies/2:filtered
```

Ordinals are legitimate here for the reason the RFC gives (§4.3): policy order is semantically
significant in Ash, and this repository's grant union in `AshEnterprise.Security.Policies`
depends on it, so an ordinal is a fact about the policy rather than an accident of listing.

Two honest caveats:

- **The authorizer must be asked.** Ash computes a decision without narrating it unless
  explanation is requested, and requesting explanation on every read is not viable. So
  `policy_decision_ids` is populated for **writes and explicit authorization checks** and is
  empty for reads, and the field's documentation must say that rather than leaving a consumer
  to infer "no policies were consulted" from an empty list. An `:unavailable` sentinel entry
  (`["policy:v0:unavailable"]`) distinguishes *not captured* from *none applied*, following
  rule 4 above.
- **Filter checks do not have a single outcome.** `AshEnterprise.Security.Policies`' grant
  union is filter-shaped: the answer is a query predicate, not a yes. For those the id carries
  `:filtered` and the applied filter's digest goes in `detail`, not the filter itself — a
  filter over a business-unit subtree is a list of tenant ids.

This is the field most likely to change shape under review. It is included because leaving it
out means the envelope answers "what ran" and "over what" but not "by what authority", which
is the one an auditor asks first.

### 2.6 `evidence_ids`

References to durable artefacts a run produced or consulted, as `<kind>:<uuid>`:

```
evaluation:018f…   # AshEnterprise.Decisions.Evaluation
audit:018f…        # AshEnterprise.Audit.EventLog (by id, not sequence — see below)
compliance:018f…   # AshEnterprise.Compliance.EventLog
process_event:018f… # AshEnterprise.Bpmn.ProcessEvent
signal:018f…       # AshEnterprise.Bpmn.Signal
```

By `id` rather than by `sequence`: the audit log's `sequence` is a per-tenant chain position
whose ordering guarantees are documented at length on `AshEnterprise.Audit.EventLog` and are
explicitly *absent* for the `NULL`-tenant chain. An id is stable in every chain.

### 2.7 Retention

The audit log has no retention or purge policy. That is a named gap
(`docs/manifesto/07-what-we-do-not-have.md`), and the immutability trigger makes the collision
with a GDPR erasure request sharper rather than softer — the log now actively refuses the
`DELETE` that erasure implies.

**The envelope's digest-only rule is the mechanism that resolves this, and it is the main
reason to prefer digests over payloads.** Three retention classes fall out:

| Class | What | Retention | Erasure |
|---|---|---|---|
| **Envelope** | ids, digests, timestamps | Indefinite | Nothing to erase — it holds no personal data by construction |
| **Payload** | `Evaluation.inputs`/`outputs`, `EventLog.data`/`changed_attributes` | Tenant policy | Erasable |
| **Evidence blob** | documents, exports, attachments | Compliance programme | Erasable |

Erasing a payload leaves its envelope intact and still verifiable: the hash chain still adds
up, the trail still says *a decision of this shape ran over an input with this digest and
produced an output with that digest*, and the only thing lost is the ability to see the
values — which is precisely what was asked for. Without the digest split, honouring an erasure
request either breaks the chain or is refused.

**One thing this does not solve, and it must be said.** `AshEnterprise.Audit.EventLog.data`
and `changed_attributes` are inside the hashed expression in the chain trigger. Erasing them
*does* break the chain today. Making payload erasure chain-safe means the trigger hashing the
payload's digest rather than the payload — a change to
`AshEnterprise.Audit.Chain.verify/1`'s SQL and to the trigger **in lockstep**, since that
module exists to keep one canonical form. That is real work, it is not in this design, and it
is the single highest-value follow-on from it.

---

## 3. Where it hooks in

Three seams, chosen because each is already the single place its subsystem passes through.

### 3.1 Action execution

`AshEnterprise.Platform.Resource` is where audit, telemetry, ownership, tenancy, soft delete
and policies are inherited — "a resource is audited and instrumented by virtue of being a
platform resource". The envelope joins that list: a new global change,
`AshEnterprise.Platform.Changes.StampProvenance`, builds the envelope and puts it in changeset
context, and `AshEnterprise.Platform.Correlation.audit_metadata/1` is extended to serialize it
into `EventLog.metadata`.

Extending `audit_metadata/1` rather than adding a parallel stamp matters: it already drops nil
values, already handles `SystemActor` attribution (which cannot be a foreign key), and already
carries `impersonator_id` — three behaviours this envelope would otherwise reimplement.

### 3.2 Process execution

`AshEnterprise.Process.EngineContext.engine_opts/2` is the one function every `ash_bpmn` host
callback goes through, and it exists because the tenant was arriving nil on some paths and the
failures were all several steps from the cause. It is the right seam for the same reason:
one function to change rather than three call sites to find.

`engine_opts/2` gains the envelope, derived from the instance
(`process_instance_id`, `correlation_id`, `started_by_id`, `trigger_depth`) and the node
(`semantic_id` as `bpmn:v0:<key>#nodes/<node_id>`, `definition_version` from the pinned
definition). `AshEnterprise.Process.ActionInvoker` then passes it through to the host action it
invokes, so a service task's audit row says which diagram node caused it — which today it does
not, and the allowlist moduledoc's point about "three distinct facts" (`started_by_id`,
`created_by_id`, `decided_by_id`) gains a fourth that is actually the causal one.

### 3.3 Decision execution

`AshEnterprise.Decisions.evaluate/3` already threads `:correlation_id` down to
`AshDecisions.Evaluator.evaluate/3`. Widen it to `:envelope`, carried in
`AshDecisions.Scope`. `AshDecisions.Evaluator.record/5` writes the envelope fields onto the
`Evaluation` row alongside the ones it already denormalizes, and picks up `matched_rule_ids`
from [`decision-validation.md`](decision-validation.md) §3.

`AshEnterprise.Process.DecisionResolver` then stops constructing a correlation id from
`ctx.instance.correlation_id` by hand and passes the envelope it was given, which is how the
BPMN→DMN join stops being a string convention.

### 3.4 Crossing process boundaries

The existing limitation is documented and real: `Correlation` is process-dictionary state, and
work handed to a `Task` or an Oban job starts a new correlation unless passed deliberately.
`with_correlation/2` exists for that.

Generalize it — `AshEnterprise.Provenance.with_envelope/2`, same shape, same
save-and-restore, same argument against implicit propagation (which is how one id ends up
spanning a server lifetime). Plus an Oban middleware that serializes the envelope into job
meta and restores it in `perform/1`, because BPMN dispatch is Oban-driven and is the path
where the id is lost today.

`trace_id`/`span_id` come from the ambient OTel span context. `Ash.Tracer` → `OpentelemetryAsh`
is already configured with no per-resource wiring, and trace ids exist in-process regardless of
whether `traces_exporter` is `:none` — so the envelope can carry them without anyone turning
exporting on, and an operator who later does gets historical rows that join to live traces.

### 3.5 What audit does with it

- **`AshEnterprise.Audit.EventLog`** — envelope keys land in `metadata`, not as new columns.
  Its schema is owned by the tamper-evident chain, and `AshEnterprise.Compliance.EventLog`'s
  moduledoc already establishes the precedent: adding columns to the most sensitive resource in
  the system to serve a consumer's SELECT is the wrong trade. `metadata` is JSONB and already
  carries four provenance keys.
- **`AshEnterprise.Audit.Export`** — `columns/0` gains `semantic_id`, `definition_version`,
  `input_digest`, `output_digest`, `trace_id`. The module's argument for including
  `sequence`/`previous_hash`/`hash` — that an export carrying them is evidence rather than a
  list of assertions — extends directly: an export carrying digests lets a recipient verify
  that the payload they were separately given is the payload that was decided over.
  There is a contract test on `columns/0`; it is the change's canary.
- **`AshEnterprise.Audit.Chain`** — envelope fields in `metadata` are **not** currently inside
  the hashed expression. They must be, or the envelope is attestable but not tamper-evident,
  which is worse than not claiming it. Changing the trigger's `concat_ws` and the SQL
  recomputation in `verify/1` together is mandatory; that module's whole thesis is that two
  implementations of one canonical form is how a verifier ends up reporting false breaks.
- **`mix ash_enterprise.audit.verify`** — unchanged in interface. Gains a second check once
  §2.7's payload-digest change lands: *does each row's `input_digest` match the payload still
  stored?* — which detects a payload edited without the envelope, the one tampering shape the
  chain alone does not see.

---

## 4. Open questions

1. **Does the envelope get its own table?** This design threads it through existing carriers
   (`EventLog.metadata`, `Evaluation` columns, `Instance` columns), which avoids a migration
   on the chain and keeps each subsystem's evidence self-contained. The alternative — one
   `provenance_envelopes` table that everything points at — makes the cross-subsystem join
   trivial and makes envelope-retention-independent-of-payload (§2.7) structural rather than
   conventional. It also adds a write to every audited action. Not resolved.
2. **Is truncating digests to 128 bits right for evidence?** The RFC truncates for readability
   in a developer tool. An envelope is an audit artefact with a longer life and an adversarial
   reader. 128 bits is collision-safe at any realistic scale, but "the RFC does it" is a
   reason about ergonomics, not about evidence, and full-length digests cost nothing here.
3. **`policy_decision_ids` for reads.** §2.5 punts: populated for writes, empty for reads,
   sentinel to distinguish. Whether a cheaper always-on capture exists — the authorizer already
   knows which policies it consulted, it just does not report them — is worth asking upstream
   before accepting the gap.
4. **Whose `semantic_id` when a run is a composition?** `AshEnterprise.Process.ActionInvoker`'s
   `grant_role` is find-or-create *plus* grant: one ref, two actions, and its registry marks it
   `:bespoke` precisely because of that. Does the envelope carry the ref's id, the inner
   actions' ids, or one envelope per action with a parent link? A parent link is the honest
   answer and is more machinery than this design has.
5. **Does `dmn:`/`bpmn:` belong in the semantic-manifest RFC?** §2.2 argues yes, as additional
   schemes under the same grammar. That is a conversation with the RFC's reviewers, and if the
   answer is no, these ids need a home that is not a second grammar in a third place.
6. **Retention enforcement.** §2.7 defines classes and no mechanism. Time partitioning on the
   audit log is the prerequisite and is already named as a pre-production gap.
