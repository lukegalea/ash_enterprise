# Policy text → declared questions: the proposal, the person, the lock

**Ticket:** S1-61 / CAP2-POLICY ("Policy text → proposed declared
questions"). **Mechanism:** `AshEnterprise.SystemOne.QuestionProposal`.
**Doctrine:** ADR 0039 (judgments are declared questions), ADR 0046 (the
declaration is the output contract), ADR 0047 (learning produces
proposals), RFC S1-24 §3 (what makes a valid declared question), S1-56
§3–§4 (model output is always an editable proposal; promotion is a
person's act).

---

## The capstone story in one paragraph

Someone writes a standard, a requirement or a policy in plain English.
An in-zone generative instrument reads it and proposes candidate
*declared questions* — answer type, options, wording, criteria, family —
each citing the clause it came from. The output is decoded under a JSON
Schema of valid proposals: what the schema admits is a well-formed
*proposal*, never a truth, and what it refuses is retained verbatim for a
person to read. A person reviews the proposals, edits the wording as
needed, and confirms. Confirmation registers nothing anywhere: it makes
the (possibly edited) text the confirmed declaration *as data*. The
person then lands the declaration as a `judgments do question ... end`
entry at version 1 on the subject resource — `to_dsl/2` renders the exact
snippet — and commits `priv/judgments/lock.json`. From that moment the
registry's own governance applies by construction: any wording drift is a
compile error, a change is a new question, and the question is judged,
recorded and admitted through the ordinary ledger lifecycle. That is the
same mechanism VendorPM's custom requirements will use: a domain
contributes policy TEXT and a subject resource — nothing else.

## The pipeline

```
policy text ──▶ in-zone generative instrument (recorded) ──▶ decode under
the wire schema ──▶ vocabulary pass ──▶ QuestionProposal (status: proposed)
                                                        │
                        person edits / confirms ◀───────┘   (or rejects)
                                │
                  to_dsl/2 → person lands the DSL entry at version 1
                                │
                  priv/judgments/lock.json (wording drift = compile error)
                                │
                  judged (judge_<name>) → ledger observation → band → fact
```

## What the schema is, and where it came from

`priv/system_one/question_proposal.schema.json` (draft 2020-12, validated
with JSV at compile time) is the contract the model decodes under. Its
derivation:

- **answer_type** mirrors `AshJudgments.Registry.Dsl`'s answer types
  (`Noul | Choice | Score`; `Evidence` ships with UP-AI-EVIDENCE-TYPE and
  is refused until then — refused, never coerced).
- **options** carry the registry's rules: a Choice's options become
  `constraints(of:)`, a Score's become `constraints(levels:)`, a Noul's
  `[true, false]` are derived and must never be model-provided. The
  abstention (`insufficient`, law 7) is appended by the registry and by
  the hash — the model never emits it (ADR 0046 point 5).
- **name / family** are atom-safe patterns: they become Spark identifiers
  and calibration-family atoms.
- **version** is not model-provided: proposals are always proposed at
  version 1, and only a person changes a question after activation
  (ADR 0039 property 6). **profile** is not model-provided either: the
  caller names the in-zone instrument.
- There is **no confidence field** on the generative rung (ADR 0046
  point 5), and every Choice carries its abstention by construction.

Cross-field rules JSON Schema cannot express — criteria keys must be
exactly the options, `pii: minimised` requires a state shape — run in the
post-decode vocabulary pass (`Schema.normalise/1`), which also refuses to
mint atoms: proposal vocabulary arrives as strings and stays strings. The
registry's canonical encoder renders atoms as their strings, so the hash
computed here is byte-identical to the hash of the declared question whose
DSL brings the atoms into existence.

## The person gates

Two gates, both structural:

1. **Confirm** (`QuestionProposal.confirm/3`) requires a person actor (a
   user row). System actors, automation principals and the `ai` label all
   fail (`PersonActor` — the post-AST-136 model: no `ai` bypass anywhere).
   Confirmation re-runs the full decode contract over the person's edited
   wording — it is the moment the wording becomes the declaration — and
   recomputes every question hash.
2. **Declaration is a separate, compile-time, person act.** Nothing in the
   mechanism writes source code or touches the registry: confirming
   changes a record's status, nothing else. The registry only ever gains a
   question when a person lands the DSL entry — and only then do judge
   actions, observations, calibration and facts become possible.

## Zones, recording, and the frozen record

The instrument call resolves through the ordinary profile machinery
(`AshJudgments.Profile.model_spec/3` — residency guard, region rule,
pin) and must name an **in-zone generative runtime** (ADR 0046 as
amended: generative instruments are in-zone only; the decision runtimes
have no generative endpoint). The proposal record is AshEvents-audited on
the platform base and carries the instrument-call identity the ledger
conventions expect: the reserved exploratory question id
(`judgment:v0:<Module>#judgments/exploratory`, S1-56 §4.2) and the wire
question hash (prompt + schema, the §3.3 discipline for an undeclared
question). The v0 ledger fragment's `answer_kind` enum does not yet admit
`extraction` rows, so the call is recorded HERE; adopting the ledger row
for proposal calls is an upstream follow-up. `policy_text` and
`raw_output` are payload class (byte-faithful, `trim?: false`, erasable);
everything else is envelope class.

## Extension point (VendorPM later, no names in core)

The mechanism contains no domain vocabulary. A new domain contributes:

1. **Policy text** — any prose, any language, from any source
   (`propose source: policy_text:`).
2. **A subject resource** — at declaration time, the person lands the
   confirmed questions on the resource whose state the questions judge,
   with a `state_projection`/`state_shape` if the model must not see raw
   state (the registry's verifiers enforce the pii rules at compile).
3. Optionally a **profile per family** — the profile is a `propose`
   argument, so different domains can use different in-zone instruments.

Nothing else. VendorPM's "a PMC's own requirement becomes questions our
team confirms" is this exact flow with private text: in-zone, in shadow,
per CAP2-VPM-MIRROR's constraints (no customer-confidential content in
commits, transcripts or public repos; residency tagged before entry).

## Where the tests live

`test/ash_enterprise/system_one/question_proposal_test.exs`: decode
success and every refusal path (malformed JSON, wrong answer type, ghost
option vocabulary, a Noul that lists its own options — raw output always
retained byte-for-byte), the confirm gate (person-only; nothing registers;
no facts; edits re-hash; re-validation on confirm), and the lock
interaction (the confirmed declaration's hash is the declared question's
hash at version 1, and `priv/judgments/lock.json` holds it — wording drift
from then on is a compile error, the registry's own `VerifyLock`).
