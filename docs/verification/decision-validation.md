# Publish-time verification for DMN decisions

| | |
|---|---|
| **Status** | Design — for review |
| **Lane** | G (enterprise verification) |
| **Work item** | Plane project AST |
| **Touches** | `ash_decisions` (compiler, resources, evaluator), `AshEnterprise.Decisions`, `AshEnterprise.Process.DecisionResolver` |
| **Companions** | [`provenance-envelope.md`](provenance-envelope.md), [`feel-type-integration.md`](feel-type-integration.md) |

---

## 1. Problem

`AshDecisions.Compiler.compile/1` is already a real verifier. Before a document can be
published it proves, and refuses on failure, that:

- the XML parses (`AshDecisions.Tck.Xml.parse/1`) and the engine loads and validates it
  (`Boxic.DMN.load_xml/1` + `Boxic.DMN.validate/1`);
- every boxed expression is `decisionTable` or `literalExpression`, and no
  `businessKnowledgeModel`, `decisionService` or `knowledgeRequirement` appears;
- the hit policy is one of `UNIQUE`, `ANY`, `FIRST`, `PRIORITY`, `COLLECT` — `OUTPUT ORDER`
  and `RULE ORDER` are refused because they make rule sequence semantically significant;
- every `informationRequirement` resolves and the DRD is acyclic;
- every *literal* FEEL expression — input expressions, output entries, default output
  entries — parses, and is within the size and depth bounds of `AshDecisions.Feel`.

`AshEnterprise.Decisions.Definition` inherits that: `CompileXml` stores `errors` on every
write, and `ErrorsEmpty` refuses `publish`. A published definition is one the compiler
accepted, and `AshEnterprise.Process.DecisionResolver` relies on that without rechecking.

**Three things it does not prove, and all three fail silently in production.**

**Input entries are unverified beyond byte size.** `AshDecisions.Compiler.rule_expression_errors/2`
says so plainly: unary tests are a separate grammar that Boxic parses inside its evaluator
rather than exposing a parser for, so only `AshDecisions.Feel.check_size/2` runs. A typo in a
cell is discovered the first time a case hits that row.

**Overlap is unverified.** A `UNIQUE` table whose rules can both match is a runtime error —
per case, per tenant, months after publish, in a path that `AshDecisions.Evaluator` records as
an `error` row and `DecisionResolver` returns as `{:error, reason}`, which a business rule task
turns into a stalled process. Nothing at publish time says the table is capable of it.

**Incompleteness is unverified, and it is the worse one.** A table with no matching rule and
no `defaultOutputEntry` returns `null`. `null` is not an error anywhere in the stack: the
evaluation row records a successful evaluation with a null output, the business rule task
promotes a null signal, and the gateway after it takes the default branch. The
`AshBpmn.Feel` moduledoc already documents the sibling of this — an equality comparison on a
missing field is plain `false`, silently — and calls it "a real diagnostic gap". The same gap
exists on the decision side and it is reachable without any type error at all: just a table
that does not cover its input space.

The `AshDecisions.Feel.to_feel_value/2` moduledoc describes the compound version, which is the
one that actually bites: an Elixir integer left unconverted makes `< 1000` a type error, FEEL
folds a type error to `null`, a decision table reads `null` as *this rule did not match*, no
rule matches, the table returns `null`, and **nothing anywhere reports a problem**.

This design closes the first two properly, makes the third visible, and — critically — says
out loud which tables it could not decide anything about rather than reporting silence as
success.

---

## 2. Design

### 2.1 Lower each input entry into a constraint, or refuse to guess

Verification needs input entries as *terms*, not text. Add a recognizer for the decidable
subset of the unary-test grammar. It runs at publish only; evaluation continues to go through
`AshDecisions.Feel.evaluate_unary_test/4` and the engine, unchanged.

The recognizer lowers one cell into a `constraint`:

```elixir
@type point   :: {:point, term()}                 # "gold"       | 42
@type range   :: {:range, bound(), bound()}       # [1..5)       | < 10
@type bound   :: {:incl, term()} | {:excl, term()} | :unbounded
@type negated :: {:not, [point() | range()]}      # not("gold", "silver")
@type any     :: :any                             # "-" or an empty cell

@type constraint ::
        point() | range() | negated() | any()
        | {:union, [constraint()]}                # top-level comma disjunction
        | {:opaque, String.t()}                   # everything else
```

`{:opaque, text}` is the sink and it is load-bearing. A cell containing a function call, a
qualified name, a reference to another input, `date(...)` arithmetic, or anything the
recognizer has not been taught, lowers to `:opaque` — never to an approximation.

> **Soundness rule, normative.** The recognizer must never narrow. If it cannot prove the
> precise constraint it must emit `{:opaque, text}`, and `:opaque` is always a legal answer.
> A false `{:point, "gold"}` turns a correct table into a reported overlap, and a verifier
> that reports false findings gets switched off — the same argument
> `AshEnterprise.Audit.Chain` makes about a chain verifier that reports false breaks. This
> mirrors the semantic-manifest RFC's rule for `dynamic`
> (`docs/rfc/semantic-manifest-v0.md` §5.2).

The recognizer reuses `AshDecisions.Feel`'s top-level comma splitter (`split_unary_tests/1`),
which already handles commas inside string literals, so the disjunction is split exactly the
way the evaluator splits it. Reimplementing the split would be the "seam that answers a cell
differently from the engine" that module exists to prevent.

### 2.2 Decidable domains

Overlap and completeness are decidable when every column's domain is a lattice the recognizer
can reason over, and every cell in that column lowered to something other than `:opaque`.

| Column domain | Source | Decidable? |
|---|---|---|
| Finite enumeration | `input/@inputValues`, or an enum `typeRef` resolved per [`feel-type-integration.md`](feel-type-integration.md) §2 | Yes — subset algebra over a finite set |
| `boolean` | `typeRef="boolean"` | Yes — two-element set |
| `number`, `date`, `time`, `dateTime`, duration | `typeRef` | Yes — interval algebra over a total order |
| `string` with no `inputValues` | — | **Points and negated points only.** Ranges over strings are decidable in principle (lexicographic) and are deliberately not attempted: nobody writes them, and the FEEL lexicographic order is a place to be wrong quietly |
| anything else, or any `:opaque` cell in the column | — | No |

A table is **decidable** when every column is decidable. Overlap and completeness are then
computed as interval/set algebra over the product of the columns: rule *i* and rule *j*
overlap iff their per-column constraints intersect in every column; the table is complete iff
the union of the rules' products covers the product of the column domains.

The product is bounded before it is built. A table with many wide enumerated columns has a
product that is large but not interesting, so the analysis is capped
(`AshDecisions.Config.verification_max_regions/0`, proposed default 100_000 regions) and a
table that exceeds the cap yields an obligation rather than a finding — see next.

### 2.3 Undecidable cases become explicit proof obligations

An undecidable table must not be reported as clean. It must not block publishing either: an
`:opaque` cell is usually a perfectly good rule using a FEEL construct the recognizer has not
been taught yet, and refusing to publish over the verifier's own incompleteness would make
the verifier the thing people route around.

So the output of verification is two lists, not one:

```elixir
defmodule AshDecisions.Verification.Finding do
  @moduledoc "Something the verifier proved about the table."
  defstruct [:kind, :severity, :path, :message, :detail, :stage]

  @type kind ::
          :overlap          # two rules can match simultaneously
          | :incomplete     # a region of the input space matches no rule, and there is no default
          | :shadowed       # a rule that can never fire (FIRST/PRIORITY, subsumed by an earlier one)
          | :unsatisfiable  # a rule whose own conjunction is empty

  @type severity :: :error | :warning | :info

  @type t :: %__MODULE__{
          kind: kind(),
          severity: severity(),
          # The DMN element id, exactly as `AshDecisions.Compiler.error/2` uses it,
          # so both lists address the document the same way.
          path: String.t(),
          message: String.t(),
          # Machine-readable: `%{rules: ["Rule_3", "Rule_7"], column: "risk_band",
          #   region: "risk_band in [700..800) and amount > 1000"}`
          detail: map(),
          stage: :parse | :type_check | :completeness
        }
end

defmodule AshDecisions.Verification.Obligation do
  @moduledoc """
  Something the verifier could **not** decide, recorded so that silence is never
  mistaken for proof.
  """
  defstruct [:reason, :path, :message, :detail]

  @type reason ::
          :opaque_entry       # a cell the recognizer would not guess at
          | :untyped_column   # no typeRef and no inputValues, so no domain
          | :unbounded_domain # a decidable type whose domain is infinite and uncovered
          | :region_cap       # the product exceeded the analysis cap
          | :hit_policy       # COLLECT/ANY: overlap is legal, so nothing to prove

  @type t :: %__MODULE__{
          reason: reason(),
          path: String.t(),
          message: String.t(),
          detail: map()
        }
end
```

An obligation is a first-class artefact, not a log line. It is what an auditor is shown
alongside the definition: *this table was proved non-overlapping and complete except for
column `escalation_reason`, which is untyped, and rule `Rule_9`, whose first cell uses a
construct the verifier does not decide.* That sentence is worth considerably more than a green
tick that means less than it looks like it means.

### 2.4 Severity by hit policy

Overlap is a defect under `UNIQUE` and a *design* under `COLLECT`. Severity is therefore a
function of the table's hit policy, which the compiler already normalizes and stores as
`graph.decisions[id].hit_policy`:

| Hit policy | Overlap | Incomplete |
|---|---|---|
| `UNIQUE` | `:error` — the engine will raise on the case that hits it | `:warning` |
| `ANY` | `:error` **only when the overlapping rules' output entries differ**; `:info` otherwise — identical outputs are what `ANY` is for | `:warning` |
| `FIRST` | `:info`, plus `:shadowed` at `:warning` for a rule an earlier rule fully subsumes | `:warning` |
| `PRIORITY` | `:info` | `:warning` |
| `COLLECT` | not applicable — an `:hit_policy` obligation instead | `:info` |

`:unsatisfiable` is `:error` under every policy: a rule whose own cells contradict each other
(`> 100` and `< 50` in the same column) is dead text in an artefact an auditor reads as law.

Incompleteness is a warning rather than an error by default, and that is the one judgement
call in this table. The argument for warning: partial tables that lean on a downstream default
are a legitimate, common pattern, and DMN supports it with `defaultOutputEntry`. The argument
for error: a null output is invisible all the way down the stack (§1). The resolution is a
per-tenant opt-in — `AshDecisions.Config.incomplete_tables/0`, `:warn | :error`, default
`:warn` — so a compliance program that needs total tables can demand them without imposing it
on everybody.

### 2.5 Where it runs

Verification is **not** part of `AshDecisions.Compiler.compile/1`. The compiler answers
"does this document mean anything?"; verification answers "is what it means sound?", it is
more expensive, and its output has a different lifecycle. A new module:

```elixir
defmodule AshDecisions.Verifier do
  @spec verify(graph :: map()) :: %{
          findings: [Verification.Finding.t()],
          obligations: [Verification.Obligation.t()],
          verified_at: DateTime.t(),
          verifier_version: String.t()
        }
end
```

It takes the compiled `graph`, not the XML — the graph already holds hit policies, clause
`type_ref`s, and the source text of every entry, which is the whole input. That keeps the
verifier off the XML layer and makes it testable against a map.

Storage: a new `verification` attribute (`:map`) on
`AshDecisions.Resources.Definition`, written by a new `VerifyGraph` change that runs after
`CompileXml` and only when `errors == []`. It is deliberately a sibling of `errors` rather
than an addition to it, because the existing contract — *`errors` non-empty is a valid draft
state and is what stops a publish* — is load-bearing and must not change meaning.

Publishing gains one validation, ordered after `ErrorsEmpty`:

```elixir
update :publish do
  validate AshDecisions.Resources.Definition.StatusIsDraft
  validate AshDecisions.Resources.Definition.ErrorsEmpty
  validate AshDecisions.Resources.Definition.VerificationClean   # new
  change set_attribute(:status, :published)
end
```

`VerificationClean` refuses only on `severity: :error`. Warnings and obligations are stored
and surfaced, never blocking.

`verifier_version` is on the row for the same reason `graph.feel_engine.version` is: a
definition published under an older verifier was proved less, and a consumer holding the row
needs to know that without re-deriving it.

---

## 3. Matched-rule-id recording at runtime

`AshDecisions.Resources.Evaluation` already has the column, and
`AshDecisions.Evaluator.record/5` already writes `matched_rule_ids: []` with the reason in the
moduledoc: `Boxic.DMN.evaluate/3` returns the decision's value and nothing about how it got
there, and a second opinion computed here could disagree with the engine's, "which is worse
than not answering".

That reasoning is right, and it rules out one of the three available designs, not all three.

**Option A — engine trace (the real fix).** Upstream a `Boxic.DMN.evaluate/4` accepting
`trace: true` and returning `{:ok, value, %{matched_rules: [id], hit_policy: policy}}`. The
decision table evaluator already computes the matched set internally; the change is exposing
it. This is the only option that yields an authoritative answer, and it is the one to pursue.

**Option B — agreement-checked replay (the interim).** After the engine answers, re-evaluate
each rule's input entries through `AshDecisions.Feel.evaluate_unary_test/4` — the same seam the
engine's own splitting is mirrored against — compute the matched set, then **apply the hit
policy to the replayed set and compare the result with what the engine returned**. Record the
rule ids only when the two agree.

This answers the moduledoc's objection directly. The objection is not that a replay might be
wrong; it is that a replay might be *silently* wrong. A replay that must reproduce the
engine's own output before its rule ids are believed cannot be silently wrong — it is either
corroborated or it is recorded as a disagreement, which is itself a finding worth having.

**Option C — do nothing.** The status quo. Costs: every audit conversation about a decision
stops at "the answer was 12%" and cannot reach "because rule 7 matched".

The evidence row must never claim more than it knows, so the mechanism is recorded alongside
the ids. One new attribute on `AshDecisions.Resources.Evaluation`:

```elixir
attribute :rule_selection, :atom do
  constraints one_of: [
    :engine_trace,      # option A — the engine said so
    :verified_replay,   # option B — a replay reproduced the engine's output
    :replay_disagreed,  # option B — a replay did not; `matched_rule_ids` stays empty
    :unavailable        # option C, or a literalExpression decision with no rules at all
  ]
  public? true
end
```

`:replay_disagreed` is the valuable one. It means the seam and the engine disagree about a
live case, which is either a bug in `split_unary_tests/1`, a bug in the engine, or a FEEL
subtlety nobody has noticed — and all three are things you want a row for.

Option B is gated by `AshDecisions.Config.rule_tracing/0` (`:off | :replay | :engine`,
default `:replay`), because it doubles the FEEL work on the decision path and a high-volume
tenant may reasonably decline. The replay runs inside the existing `bounded/2` timeout, so a
pathological table cannot turn evidence collection into a stall.

---

## 4. Explanation: rule selection and null propagation

Matched rule ids answer *which*. They do not answer *why not* — and "why did no rule match"
is the question §1 says is currently unanswerable.

An explanation is produced on demand, not on every evaluation. It is what the designer's
preview renders and what an auditor requests against a stored `Evaluation` row; it is not
stored, because it is derivable from the definition plus the inputs, both of which the row
already carries denormalized (`definition_key`, `definition_version`, `inputs`).

```elixir
defmodule AshDecisions.Explanation do
  defstruct [:decision_id, :hit_policy, :columns, :rules, :selection, :nulls]

  @type column :: %{
          id: String.t(),
          label: String.t(),
          expression: String.t(),
          # The value the engine actually saw, rendered by `AshDecisions.Feel.print/1`
          # so the auditor reads FEEL rather than `#Decimal<12.5>`.
          value: String.t(),
          type_ref: String.t() | nil
        }

  @type cell_verdict :: :match | :no_match | :null | :not_evaluated

  @type rule :: %{
          id: String.t(),
          description: String.t() | nil,
          cells: [%{column_id: String.t(), entry: String.t(), verdict: cell_verdict()}],
          matched?: boolean()
        }

  @type selection :: %{
          matched_rule_ids: [String.t()],
          # Why the hit policy chose what it chose: `:sole_match`, `:first_of`,
          # `:highest_priority`, `:collected`, `:no_match_default`, `:no_match_null`.
          reason: atom(),
          output: String.t()
        }

  @type null_source :: %{
          path: String.t(),          # "applicant.credit_score"
          # `:absent` — the key was never supplied.
          # `:dropped_not_loaded`   — `%Ash.NotLoaded{}` removed by `to_feel_value/2`.
          # `:dropped_forbidden`    — `%Ash.ForbiddenField{}` removed by `to_feel_value/2`.
          # `:type_error`           — present, wrong FEEL type, folded to null.
          # `:evaluated_null`       — a FEEL expression legitimately returned null.
          cause: atom(),
          affected_rule_ids: [String.t()]
        }
end
```

`nulls` is the part that earns this structure. Every one of the five causes presents
identically at runtime — a rule that does not match — and they have entirely different
remedies:

- `:dropped_forbidden` means **the actor could not read a field the decision needed**, and the
  decision went the other way because of an authorization boundary. `to_feel_value/2` drops
  rather than nils it deliberately, and the moduledoc gives the reason: nilling "would let a
  hidden value decide a case". Dropping is correct, and *not saying it happened* is not.
- `:dropped_not_loaded` is a caller bug: a relationship the decision needs was not loaded.
  Indistinguishable from `:absent` at runtime, distinguishable here.
- `:type_error` is the integer-that-should-have-been-a-`Decimal` failure. Once
  [`feel-type-integration.md`](feel-type-integration.md) stage 1 ships, most instances of
  this become a publish-time finding instead of a runtime explanation.

The explanation is computed by the same replay machinery as option B in §3, so the two ship
together: a replay that can produce per-cell verdicts is a replay that can corroborate the
matched set, and vice versa.

---

## 5. Integration points

| Module | Change |
|---|---|
| `AshDecisions.Compiler` | Unchanged in behaviour. Its `%{path:, message:}` error shape is reused verbatim by `Finding` and `Obligation` so both address the document identically. |
| `AshDecisions.Verifier` | **New.** `verify/1` over the compiled graph. |
| `AshDecisions.Verification.{Finding,Obligation}` | **New.** Structs above. |
| `AshDecisions.Explanation` | **New.** §4. |
| `AshDecisions.Feel` | `split_unary_tests/1` promoted to public (with offsets — see [`feel-type-integration.md`](feel-type-integration.md) §3) so the recognizer and the evaluator split one way. No other change; the seam stays the only caller of `Boxic.FEEL`. |
| `AshDecisions.Config` | `verification_max_regions/0`, `incomplete_tables/0`, `rule_tracing/0`, alongside the existing `feel_*` bounds. |
| `AshDecisions.Resources.Definition` | New `verification` attribute; new `VerifyGraph` change on `:create`/`:save_xml`; new `VerificationClean` validation on `:publish`. |
| `AshDecisions.Resources.Evaluation` | New `rule_selection` attribute; `matched_rule_ids` actually populated. Still append-only: no update, no destroy. |
| `AshDecisions.Evaluator` | `record/5` writes `matched_rule_ids` and `rule_selection`; the moduledoc's "what is not recorded" section is rewritten rather than deleted, because the *reason* it said so is still the reason option B is corroborated rather than trusted. |
| `AshEnterprise.Decisions.Definition` | No change — it inherits the new attributes through `AshDecisions.Resources.Definition`. Requires `mix ash.codegen` for the new columns. |
| `AshEnterprise.Decisions.evaluate/3` | No change to the contract. The `:record` option continues to suppress evidence for designer previews, and an explanation is available for previews precisely because it is not stored. |
| `AshEnterprise.Process.DecisionResolver` | No change. It already returns `{:error, reason}` on a failed evaluation; publish-time verification reduces how often that path is a `UNIQUE` violation rather than changing what happens when it is. |
| `AshEnterpriseWeb.Live.Decisions.EditorLive` | Renders findings and obligations next to the existing `errors`, and the explanation for a preview evaluation. This is where the design either becomes useful or does not. |

Migrations: three new columns (`dmn_definitions.verification`, `dmn_evaluations.rule_selection`)
via `mix ash.codegen verification` — never hand-written, per the repository's non-negotiables.

---

## 6. Open questions

1. **Does `boxic_dmn` want option A?** The matched set exists inside its decision table
   evaluator; exposing it is a small, additive change. Worth asking before building option B,
   because if A lands, B becomes a corroboration mode rather than the primary path. (Do not
   build a parallel tracer — extend upstream.)
2. **Where do `inputValues` come from in practice?** The decidability of enum columns rests on
   `input/@inputValues`, which dmn-js writes only when the author fills in the field. If real
   documents mostly omit it, §2.2 collapses to "typed scalars only" and the completeness check
   is much weaker than it reads. This needs measuring against the TCK corpus and against
   whatever documents `AshEnterprise.Decisions` actually holds, before the stage-2 rollout in
   [`feel-type-integration.md`](feel-type-integration.md) §4 is committed to.
3. **Is `:warning` the right default for incompleteness?** §2.4 argues yes on the balance of
   evidence and the opt-in resolves it, but the invisible-null failure is severe enough that
   the opposite default is defensible.
4. **Should verification run on retire?** A retired definition can still be referenced by
   historical evaluations. Re-verifying it under a newer verifier would give better
   obligations for an old audit, and would also mean the stored `verification` map changes on
   a resource whose XML is immutable — which is a new and slightly uncomfortable thing. Left
   out of this design.
5. **Tenant-forked definitions.** `AshEnterprise.Process.Binding` lets a tenant fork a
   platform decision. A finding on the platform baseline is not automatically a finding on
   every fork, and vice versa. Nothing here surfaces "your fork has an overlap the baseline
   does not" — which is probably the single most useful report this machinery could produce
   and is deliberately out of scope for v0.
6. **Cost on the publish path.** `VerifyGraph` runs on every `save_xml`, which is every
   keystroke-adjacent save in the designer. The region cap bounds the worst case but the
   typical case is unmeasured. If it is material, move verification to publish only and accept
   that the designer shows findings later than it shows compile errors.
