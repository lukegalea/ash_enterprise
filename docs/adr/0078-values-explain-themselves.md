# ADR 0078 — Values explain themselves

- **Status:** proposed (2026-11-19)
- **Date:** 2026-11-19
- **Related:** [ADR 0012](0012-openlineage-and-marquez.md) (OpenLineage carries jobs and datasets, never values),
  [ADR 0023](0023-impersonation-is-attribution.md) (provenance columns and impersonation),
  [ADR 0024](0024-audit-retention-and-erasure.md) (crypto-shredding, the archive),
  [ADR 0040](0040-record-dont-recompute.md) (record, don't recompute),
  [ADR 0049](0049-temporal-resources-are-the-validity-substrate.md) (temporal resources),
  [ADR 0052](0052-self-service-actions.md) (self-service actions),
  [ADR 0059](0059-version-number-is-an-optimistic-lock.md) (`version_number`),
  [ADR 0067](0067-a-document-is-a-pure-function-of-recorded-inputs.md) (keyed payload hashes),
  [ADR 0069](0069-a-recipe-runs-on-an-authority-chosen-per-version.md) (the cause is never authority),
  [ADR 0073](0073-secured-columns-are-grants.md) (secured columns),
  [ADR 0080](0080-what-if-is-a-scenario-on-the-simulation-twin.md) (execution context),
  [ADR 0083](0083-an-ontology-facade-is-a-resource-over-resources.md) (ontology façades).
  Amends [thesis 3](../manifesto/03-authorization-is-data.md).

## Context

A person looking at a value asks where it came from: which action wrote it, as whom, from what, under which rule or
version, and whether the record of that can be trusted. The application holds most of the answer, spread over records
that each answer part of it:

- **The audit log** (`Audit.EventLog`) records every create, update and destroy on a platform resource, with the
  actor, the correlation id and the changed attributes. A `sensitive?` attribute is written as `nil`, keeping its key
  (`Audit.Changes.RedactSensitive`). After ninety days an event moves to `Audit.ArchivedEvent`, verified, and the
  archive is never purged before four hundred days (ADR 0024, the age half).
- **The provenance columns** (`created_by_id`, `modified_by_id` and their `*_on_behalf_by_id` pair) say who created and
  last modified each row, and survive any retention window (ADR 0023).
- **Package records** answer for their own values: a decision's `Evaluation` keeps its inputs, outputs,
  `matched_rule_ids`, `hit_policy` and `error` (ash_decisions, matched rules recorded since 2026-09-23, 787fa47); a
  judged fact keeps its admission; an MDM golden value keeps the statements it was folded from; a ledger event keeps
  its `provenance` and mapping hash.
- **The execution trace** (`AshAgent.Execution.Source`) already reads one piece of work's records as the viewer and
  maps them to entries with one shape, each naming its record as `"<type>:<id>"` and saying `recorded?: false` when
  what it held was not recorded or can no longer be read.

What is missing is one shape for the answer, one address for the question, and one rule for what a reader may learn
from it. Without them, each surface that wants to say "why" (a record page, a review screen, the assistant) writes its
own walk over these records, and each one decides on its own what to do with a value the reader cannot see, an event
that was erased, a decision that recorded no rule, or an antecedent in another business unit. Those are exactly the
places a hand-written walk leaks (an identifier of a row the reader cannot read) or lies (an erased value shown as
empty, a missing rule shown as "no rule matched").

Thesis 3 makes inaccessible rows invisible rather than forbidden. An explanation crosses rows: a value the reader may
see can be derived from rows they may not. The thesis does not say what such an answer shows. This record does.

## Decision

**Any value a person can read can be asked to explain itself. The answer is a list of PROV-DM steps and typed gaps,
read as that person, through one dispatch, and nothing in it is more than they could read one record at a time.**

### 1. The address

A value is addressed by an IRI:

    <base>/<type>/<id>[?as_of=<instant>]#<attribute>

- `<base>` is the deployment's configured base IRI (`https://app.example.com/id`).
- `<type>` is a short token the host's explainer registry gives each resource. It is declared, not derived from the
  module name, so renaming a module does not move an address. It is the same token the resource's trace source uses in
  `"<type>:<id>"`. The registry refuses two resources with one token.
- `<id>` is the primary key, percent-encoded per RFC 3986: every character outside the unreserved set is encoded,
  with upper-case hex. A composite key is `k1=v1;k2=v2`, in the resource's declared primary-key order, with `=` and `;`
  inside a value encoded. A UUID or an integer is unreserved characters only, so its encoded form is itself.
- `as_of` is RFC 3339 in UTC with a `Z` suffix and the precision the resource stores. It is accepted only on a
  temporal resource (ADR 0049) and refused on any other, never silently dropped. It sits in the query, before the
  fragment, as RFC 3986 §3 orders them: a `?` after the `#` would be part of the fragment.
- `<attribute>` is the fragment: the value within the record.

Examples: `https://app.example.com/id/credential/3f6c1e0a-7b1d-4c55-9a7e-2f1d0c9b8a71#expires_on`, and for a
composite key `https://app.example.com/id/membership/team_id=7;user_id=12#role`.

**One-to-one with trace references.** Dropping `<base>` and the fragment, and joining the remaining two segments with
`:`, gives the trace reference `"<type>:<id>"`, and the reverse is exact. Every record reference the trace sources
emit today names a UUID and is already in this form. The `"source:<name>"` reference a trace gives a source it could
not read names a source, not a record, and has no address: in an explanation it is a `:failed` gap.

### 2. The parts

The contract is pure data in its own package, `ash_provenance`: no data layer, no dependency on `ash_agent`, read
only, and no proposal code.

**EntityRef.** `%{resource, id, version_number}` (ADR 0059's lock column, when the resource has one), plus `as_of` on a
temporal resource, and an optional `content_digest`. A `content_digest` of personal content is keyed under the
subject's erasure scope, with `Erasure.Crypto.derive_key/2` and `keyed_digest/2` under its own label, as ADR 0067
(decision 4) keys a payload hash; otherwise it is omitted. It is never a plain hash, which a dictionary reverses, and
never a key the deployment holds for everyone (`Mdm.AssertionDigestKey` is keyed, but under `secret_key_base`, so a
shred does not reach it). Once a scope's key is destroyed nobody can recompute the digest. A definition's hash (a
process, a decision table, a mapping, a lens) is not personal and stays plain.

**Step.** One PROV-DM relation: `was_generated_by`, `was_derived_from`, `used`, `was_attributed_to`,
`was_associated_with`, `acted_on_behalf_of`, `was_invalidated_by`, `was_revision_of` or `had_primary_source`. A step
carries:

| Field | Holds |
|---|---|
| `entity` | an EntityRef, or the address of a value |
| `activity` | the action, run, evaluation or invocation, by trace reference |
| `agent_label` | who, subject to decision 6 |
| `plan` | what ran, as `key@version#hash8` (the first eight hex characters of the definition's SHA-256); a trace entry's `definition_ref` (`key@version`) is the same value without the hash |
| `at` | when |
| `execution_context` | the context the write ran in ([ADR 0080](0080-what-if-is-a-scenario-on-the-simulation-twin.md)) |
| `granularity` | `:value` (this attribute) or `:record` (the record, when the evidence is no finer) |
| `summary` | a short, structural description: never sealed content, arguments, messages or judged text |
| `integrity` | optional; decision 7 |

Agents are mapped once, here, so every explainer agrees:

- **Impersonation** (ADR 0023): the activity `was_associated_with` the subject, whose authority it ran on, and with
  the operator, who `acted_on_behalf_of` the subject.
- **A recipe step** (ADR 0069): `was_associated_with` the `recipe_runner` principal, which `acted_on_behalf_of` the
  version's accountable person. The person who caused the triggering event is never an agent of the step: the dispatch
  `used` that event, and that is all.
- **A governed invocation or an agent run**: the principal `acted_on_behalf_of` the requester.
- **A system actor** is labelled by its name (`system_actor` in the event's metadata), so "the nightly job did this"
  stays distinct from "not recorded".

A step whose context was not recorded carries `execution_context: nil` and reads as "not recorded", never as live.
A source that holds only live writes by construction may declare that once, as a reviewed declaration in the source.

### 3. Typed gaps

Where the answer stops, it says why, with one of five kinds:

- `:unreadable`: the antecedent exists and the reader may not read it (decision 6).
- `:failed`: an explainer or a source errored, or the record it reads recorded an error. Never read as "nothing
  happened".
- `:erased`: the content was shredded (ADR 0024). The step is `was_invalidated_by` the shred, whose receipt
  (`Erasure.PersonErasure`'s, or the `Scope.shred` audit event) is named only to a reader who may read it; anyone else
  sees `:erased` and nothing more.
- `:not_recorded`: the record exists and what would explain it was never captured. A trace entry with
  `recorded?: false` is `:not_recorded` or `:erased`, whichever applies.
- `:archived`: the evidence is past the archive's reach: purged after the four-hundred-day floor, or held where this
  deployment cannot read it (a dumped archive table). An event older than ninety days is not a gap: it is read from
  `Audit.ArchivedEvent`, under the same grants as the hot log.

**Decisions.** An `Evaluation`'s `matched_rule_ids` is read with its neighbours:

| Row | Means |
|---|---|
| `matched_rule_ids` non-empty | these rules matched |
| `[]` and `hit_policy` set, no `error` | no rule matched: a real answer, not a gap |
| `[]` and `error` set | `:failed` |
| `hit_policy` nil and no `error`, or recorded before 2026-09-23 | `:not_recorded` |

A materialiser decision that wrote nothing (`AshJudgments.Facts.Replay` does not record `:review` or an idempotent
`:unchanged`) is `:not_recorded`.

**Bounds.** An explanation stops at a depth and a step count, both stated in the answer with whether they cut it.
There is no silent cap.

### 4. Dispatch

The host owns the registry and the walk; packages own explainers. For an address, the first of these that answers
gives the steps, and each antecedent it names is dispatched again:

1. **A package explainer** declared for the resource and attribute: MDM statements and matches, judged facts,
   planning, ledger events, strangler observations, and the ontology-façade explainer, which steps through the
   façade's lens to the source value and continues with the source's own explainer
   ([ADR 0083](0083-an-ontology-facade-is-a-resource-over-resources.md)). The façade ADR maps each refused or
   non-invertible field to one of the five gap kinds and adds none.
2. **The derived-value explainer**: a calculation or aggregate `was_derived_from` what it reads. A decrypting
   calculation over sealed content (`Erasure.Calculations.Unseal`) is not a derivation, and is passed over.
3. **The audit explainer**: the latest event that changed the attribute `was_generated_by` its action, read from the
   hot log and then the archive, as the reader. A `sensitive?` attribute was recorded as `nil`, so the answer for it is
   at `:record` granularity: this event changed it, with no value.
4. **The ADR 0023 columns**, at `:record` granularity: who created and last modified the row, and on whose behalf.

A test pins the order for `Canonical.Person.email`, which is sealed under a per-person scope and read through
`Unseal`: no package or derived explainer claims it, the audit explainer answers at `:record` granularity, and after
the person's scope is shredded the answer is `:erased`.

### 5. What an explanation is read as

Every read an explainer makes is made as the reader, through the resource's own read action, with their actor and
tenant, as the trace sources already read. An explainer that reads past a policy is a bug in the same sense as a policy
check that queries. The explain action itself grants nothing: it reaches only what the reader's own reads reach, so it
is declared self-service on the resource that hosts it (ADR 0052), and the assistant's `explain` tool calls the same
action ([thesis 5](../manifesto/05-agents-are-users.md)).

### 6. What a reader may learn

- **An unreadable subject is not found.** Asking about a value on a row the reader cannot read returns the same answer
  as asking about a row that does not exist.
- **An unreadable antecedent is a gap with no identifiers.** A readable value derived from a row the reader cannot read
  shows `:unreadable` in that place: no id, no type, no time, no label.
- **Audit-sourced values pass the target's own rules.** A value the audit explainer shows from `changed_attributes`
  must pass the target field's policy and, for a secured column, its ADR 0073 grant, as the reader, now.
- **Secured columns are never audit-sourced, and never recursed through.** Every secured column is `sensitive?`
  (`Platform.Verifiers.SecuredFields`), so the log holds `nil` for it, but it keeps the key, and "this column changed
  at this time" is itself what the column's grant withholds. The audit explainer does not answer for a secured column
  at either granularity. The derived-value explainer names a secured column as an antecedent and stops there, whether
  or not the reader holds its grant.
- **A hidden value is masked, never empty.** A value the reader may not see renders as masked text, as a page renders
  `Ash.ForbiddenField` (ADR 0073, decision 8). An empty string or `null` would read as a known, empty value.
- **An actor's label needs a read of the actor.** `agent_label` names a person only when the reader may read that
  person's record through its own read action; otherwise it says "a person", "an automation principal" or "the system",
  and never guesses.

### 7. Integrity

A step may say whether the record it rests on is anchored in a verified chain. `integrity` is
`%{anchor, status, verified_at}`:

| `anchor` | `status` from | Values |
|---|---|---|
| `:audit_chain` | `AshEvents.Chain.verify/2`, hot and archived rows as one chain | `:verified`, `:altered`, `:broken_link`, `:unchained` |
| `:ledger_chain` | the ledger's per-region verification, whose chain hashes `provenance` | the same four |
| `:signature_record` | `AshSignatures.Completion.intact?/1`; the record carries the audit chain head | `:verified`, `:altered` |

- The status is the verifier's vocabulary, unchanged. A row is `:verified` only when the latest verification of its
  chain covered it and found nothing at or before it. A row in the leading run written before the chain existed is
  `:unchained`, not `:verified`, although the verifier does not count it as a finding: claiming tamper-evidence for a
  row that never had it is the opposite error.
- It is read from a recorded verification (the daily audit-chain evidence) or computed on one record, never a walk of
  a whole chain inside a read. A missing `integrity` means "not checked" and never reads as verified.
- It shows the status of the reader's own step only. Where a break is, how many rows fail and which ones, stay with the
  compliance finding and its own grants.

### 8. Interchange

The export is PROV-O as JSON-LD and nothing else. PROV-O terms carry every PROV-DM relation. The gap kinds,
`granularity`, `execution_context`, `integrity` and the masked marker are terms in the package's own namespace,
documented with it. A hidden value has no `prov:value`. The package's CI validates its fixtures with the `prov`
Python library (MIT, CI only), and no fixture holds an unkeyed digest of personal content.

## Does it consume ActorContext?

Yes, and it adds nothing to it. Every read in an explanation is the reader's own, through each resource's policies,
field policies and ADR 0073 grants, built from the reader's precomputed context. No check queries and none uses
`forbid_if`: a gap is what a union of grants that does not reach a row looks like from a row it does reach. The chain
verifiers read as machinery, with no actor, and the explanation shows only a status on a step the reader already
reads.

## Consequences

- One answer to "where did this come from" serves the record page, review screens and the assistant, and each new
  package adds an explainer rather than a walk.
- A reader can tell apart: no rule matched, the rule was not recorded, the evaluation failed, the content was erased,
  the evidence was purged, and a source they may not read. None of them reads as empty or as a clean answer.
- The audit explainer is coarse for sensitive attributes and silent for secured ones. That is the cost of not keeping
  their values in the log, and it is the right direction.
- An explanation reads many records as one person, so it costs a page of reads per hop. The stated bounds keep it
  finite and visible.
- Execution context is "not recorded" on every step written before it is stamped. That is honest and noisy until the
  stamping lands.
- The `<type>` token is now part of a stable identity. Changing one breaks every address and trace reference that used
  it, so the registry treats a token as permanent.
- OpenLineage is unchanged (ADR 0012): it describes jobs, runs and datasets, carries no value, actor or tenant, and is
  joined to an explanation only by the correlation id. A PROV-O export is a read under grants and is never sent to a
  lineage backend.
- A document's value explains through its lineage snapshot (ADR 0067), by hash and reference: the record is read,
  never re-rendered to find out (ADR 0040).
- Competing MDM statements are explained by their sources and dates only, not their values, until statements are
  sealed per subject.

## Reversal

The contract is data with no table. Dropping it means removing the explain action, the registry and the explainers;
nothing is migrated and no record changes. Moving the contract into `ash_open_lineage`, its alternative home, is a
module move with the same shapes. Writing `as_of` after the fragment (`#<attribute>?as_of=`) would put it inside the
fragment, where an RFC 3986 parser sees no query; the address would need its own parser. Relaxing decision 6
(identifiers for unreadable antecedents, audit-sourced secured columns) cannot be undone for what was shown: it is a
disclosure, and it needs its own record. Keyed digests already issued become unverifiable with their scopes whatever
this record later says, which is their purpose.

## Amendment, 2026-11-26 — the Why page and the tool's value form

The first two surfaces over `explain` are in place, both behind the `ont_why` flag ([ADR 0072](0072-ash-native-tenant-flags.md)),
which offers them and authorizes nothing:

- **The Why page** (`/app/why`) is a report over `Explanation.why`, which answers through `explain` and projects the
  answer into rows (`AshEnterprise.Provenance.Why`): steps first, then gaps, then a row saying so when the walk cut
  the answer short. A value the reader may not see is the masked text, and a step that shows no value has no value
  column. A person pastes the address; a record page that links to it comes later.
- **The assistant's `explain` tool** takes an `address` in place of a `ref`, and `/mcp` serves the tool. The rows are the
  page's, and carry structure only: who, when, in what context, the chain status and where the answer stops, with a
  value shown as the masked text when it was hidden and never otherwise. That is why this form is not behind the
  zone gate (ADR 0042): the gate keeps content from a model outside the zone, and there is none in these rows. The
  `ref` form is unchanged, and an MCP client still gets the gate's refusal for it.
- An unreadable subject and a missing one get one answer, as decision 6 requires.

## Amendment, 2026-11-27 — an answer the evidence does not support says so

A review of the first explainers found five places where an answer read as explained, or dropped what it had found.
Each is now a typed gap or a shown field:

- **An empty answer is a pass.** An explainer answer with no steps, no antecedents and no gaps does not end the
  dispatch, so a value nothing can explain ends in `:not_recorded` (or the record columns), never in an answer with
  nothing in it. A function calculation names no inputs and passes. A module calculation whose `load/3` names a
  relationship or an aggregate is one `:record` step over it, as an expression ref through a relationship already was.
- **An audit step must have written the value.** The audit explainer restores the value the event recorded
  (`changed_attributes`, else `data`) and compares it with the value the reader reads now. When they differ (a write
  outside the recorded actions left today's value), the step is at `:record` granularity with no value, and a
  `:not_recorded` gap says the newest recorded write does not show the current value. A value hidden from the reader is
  not compared.
- **No recorded write is a gap.** On an audited resource, an attribute with no event in the hot log or the archive is a
  `:not_recorded` gap (its history was purged, or it was written outside the recorded actions), and the record columns
  still answer after it. A reader whose grants do not reach the log gets no such gap: for them, no event is no
  evidence.
- **A blanked field reads as erased.** A person erasure blanks the plaintext `sensitive?` fields it cannot shred. On a
  row whose erasure scope a person erasure shredded, such a `nil` is `:erased` with the receipt, for a reader who may
  read the receipt. A reader who may not is told nothing about an erase, because only the receipt says one happened.
- **The surfaces show whom an act was for, and what a step used.** The Why page and the tool's rows carry
  `on_behalf_of` and `from`, so a recipe-written value names its accountable publisher and the standing grant
  (`agent_start_grant:<id>`), and an impersonated write names both the operator and the person whose authority it ran
  on.

## Manifesto amendment

Thesis 3 carries this record's rule for explanations as a dated amendment:
[Amendment, 2026-11-19 — an explanation is a read](../manifesto/03-authorization-is-data.md).
