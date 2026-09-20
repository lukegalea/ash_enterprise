# Typing FEEL against Ash attributes and process variables

| | |
|---|---|
| **Status** | Design — for review |
| **Lane** | G (enterprise verification) |
| **Work item** | Plane project AST |
| **Touches** | `ash_decisions` (compiler, FEEL seam), `ash_bpmn` (compiler, FEEL seam), `boxic_feel` (upstream), `AshEnterprise.Process` |
| **Parallels** | `docs/rfc/semantic-manifest-v0.md` — vocabulary and staging are reused from it, not reinvented |
| **Companions** | [`decision-validation.md`](decision-validation.md), [`provenance-envelope.md`](provenance-envelope.md) |

---

## 1. Problem

FEEL expressions in this platform are typed nowhere, and the failures are all silent.

**The compiler checks syntax, not types.** `AshDecisions.Compiler` parses every literal
expression and output entry through `AshDecisions.Feel.parse/2`, which proves the text is
grammatical, within 4096 bytes and within 32 levels of nesting. It proves nothing about
whether `> 1000` will ever be compared against a number.

**FEEL folds type errors to `null`, and a decision table reads `null` as "no match".** The
`AshDecisions.Feel.to_feel_value/2` moduledoc calls this out as the single most consequential
line in the adapter: an Elixir integer left unconverted makes `< 1000` a type error, the error
folds to `null`, the rule does not match, no rule matches, the table returns `null`, and
nothing anywhere reports a problem. The conversion to `Decimal` is what stands between a
working table and a silently empty one — and it is a runtime convention, not a checked
property.

**The same hole exists on the process side, and `ash_bpmn` documents it.** `AshBpmn.Feel`
records that an *ordering* comparison on a missing field yields `null` and leaves a
`:condition_null` process event to find, while an *equality* comparison on the same missing
field is plain `false` and takes the default branch silently. It calls this "a real diagnostic
gap ... not one we can close without departing from the specification, so it is written down
instead". Correct — it cannot be closed at runtime. It can be closed at publish time, by
knowing that `subject.amount` is a field that exists and what type it has.

**And a diagnostic cannot point at anything smaller than an element.**
`AshDecisions.Compiler` reports `%{path: element_id, message: text}`. There is no span, and
there is no mechanism to produce one:

- `AshDecisions.Tck.Xml` wraps `:xmerl`, and the `xmlElement` record has **no line or column**
  — its `pos` field is the sibling ordinal, not a source position (verified against
  `xmerl-2.1.8/include/xmerl.hrl`).
- `Boxic.FEEL.Tokenizer.tokenize/1` emits positionless tokens: bare atoms and
  `{:identifier, "name"}` / `{:string, value}` two-tuples.
- `Boxic.FEEL.Error` is `%{code: atom, message: binary}` and nothing else.

So an author with a 12-column table and a type error is told which rule, not which cell, and
never which character.

---

## 2. A minimal type algebra

### 2.1 Reuse the manifest's vocabulary

FEEL's type system is small — `number`, `string`, `boolean`, `date`, `time`,
`date and time`, `days and time duration`, `years and months duration`, `list<T>`,
`context<…>`, `function`, `Any`, `Null` — and the semantic-manifest RFC (§5.2) already
defines a JSON type algebra with thirty kinds taken from `Ash.Info.Manifest.Type`, plus six
for DSL and generated boundaries.

This design adds **no new type kinds**. Every FEEL type maps onto a manifest term, so a tool
that already consumes manifest types consumes FEEL diagnostics with no new vocabulary.

| FEEL type | Manifest term (RFC §5.2) | Ash types that reach it |
|---|---|---|
| `number` | `decimal` | `:integer`, `:float`, `:decimal` — all three, via `to_feel_value/2` |
| `string` | `string` | `:string`, `:atom`, `Ash.Type.Enum`, `:uuid`, `:ci_string` ⚠ |
| `boolean` | `boolean` | `:boolean` |
| `date` | `date` | `:date` |
| `time` | `time` | `:time`, `:time_usec` |
| `date and time` | `datetime` | `:utc_datetime`, `:utc_datetime_usec`, `:naive_datetime` |
| `days and time duration` | `duration` | `:duration` |
| `years and months duration` | `duration` with `constraints.units: "months"` | `:duration` |
| `list<T>` | `array` with `item_type` | `{:array, t}`, has_many when preloaded |
| `context<…>` | `map` with `fields` | `:map`, `:struct`, embedded resource, belongs_to when loaded |
| `Any` | `dynamic` with `reason` | `:term`, `:union`, anything unresolved |
| `Null` | — (absence) | `nil`, and anything `to_feel_value/2` drops |

⚠ **`ci_string` is a finding, not a mapping.** FEEL has no case-insensitive string, so
`:ci_string` normalizes to `string` and `= "GOLD"` stops matching `"gold"`. That is a real
semantic change at the boundary and the type checker should say so rather than quietly widen.

### 2.2 `to_feel_value/2` *is* the accepted/normalized boundary

The RFC's central type claim (§5.1) is that a generated boundary's accepted surface is wider
than its normalized one, because casting, defaults, aliases and unknown-input handling are part
of the contract — and that a manifest reporting only one of them "is lying to at least one
consumer".

`AshDecisions.Feel.to_feel_value/2` is precisely such a boundary, and the split lands on it
exactly:

| Slot | **accepted** | **normalized** |
|---|---|---|
| a `:integer` attribute | `integer` | `decimal` |
| an `Ash.Type.Enum` attribute | `type_ref` to the enum module | `literal_union` of its values as strings |
| an `:atom` attribute | `atom` | `string` |
| a `%Ash.NotLoaded{}` / `%Ash.ForbiddenField{}` | the field's declared type | **absent** — dropped, not nilled |
| a `:map` | `map`, `open: true` | `map`, `open: false`, string keys |

The enum row is the one that pays for the whole exercise. An `Ash.Type.Enum` normalizes to a
`literal_union` of strings, which is a **finite, closed domain** — and a finite domain is what
[`decision-validation.md`](decision-validation.md) §2.2 needs to decide completeness. Without
typing, an enum-valued column is just "a string" and completeness is undecidable; with it, "no
rule covers `:escalated`" is a publish-time finding.

The dropped row is the other. `to_feel_value/2` drops unloaded and forbidden fields rather than
nilling them, deliberately — nilling "would let a hidden value decide a case". Typed, the same
fact becomes checkable: an expression referencing a field the *action's* actor cannot read is a
warning at publish, not a mystery at runtime.

> **Soundness rule, normative, carried verbatim from RFC §5.2.** An emitter must never narrow.
> If it cannot prove the narrow type it must emit the wider one, and `dynamic` is always a
> legal answer. A false `literal_union` is worse than an honest `dynamic`, because it turns a
> working program into a reported error.

FEEL's `Any` is the sink and the two coincide: unresolvable ⇒ `dynamic` ⇒ `Any` ⇒ no finding.

### 2.3 The typing environment

The environment is the reason this is tractable: it is small and closed.

**Decision tables.** Two halves.

- *Declared:* `inputExpression/@typeRef` and `output/@typeRef`, already captured by
  `AshDecisions.Compiler` into `graph.decisions[id].inputs[].type_ref` and `outputs[].type_ref`.
  Free.
- *Actual:* what the caller passes. For `AshEnterprise.Decisions.evaluate/3` the caller is
  application code; for a business rule task it is the evaluated `ash:decision` inputs. The
  declared half is checkable on its own (cells against their column's `typeRef`); the actual
  half requires the caller to declare its contract, which is the process case below.

**Process variables.** The environment is remarkably small, and deliberately so:

- `subject.<path>` — the host record, loaded by `AshBpmn.Subject.load/3`. Its type is the
  subject resource's Ash attributes, reachable through `Ash.Resource.Info`.
- `routing.<name>` — signals promoted by a business rule task. `AshBpmn.Resources.Token`'s
  `routing` attribute is documented as the one place a token carries anything beyond node ids
  and status, and the interpreter *enforces* the shape rather than documenting it: "scalars
  only, short names, short values, and few of them". So `routing.<name>` types as
  `union(string | decimal | boolean)`, and nothing else is in scope.

That closedness is what makes gateway-condition type checking feasible where general
expression typing would not be.

**One thing is missing and must be declared.** The subject's *type* is
`Instance.subject_type`, a module name stored as a string on a row that does not exist until
the process runs. At publish time there is no subject. So typing `subject.amount` requires the
diagram to say what it is about:

```xml
<bpmn:process id="access_request_approval">
  <bpmn:extensionElements>
    <ash:subject resource="AshEnterprise.Security.AccessRequest"/>
```

This follows the conventions `ash_bpmn` already has — `ash:decision ref= name= binding=` and
`ash:signal from=` are compiler-validated extension elements in
`AshBpmn.Compiler.Graph`. `ash:subject` is optional; its absence means `subject.*` types as
`Any`, every check over it is skipped, and the definition compiles exactly as it does today.
Opting in buys checking; not opting in costs nothing. That is the only way to add a type system
to an existing corpus of tenant-authored diagrams.

### 2.4 Data structures

```elixir
defmodule AshEnterprise.Feel.Types do
  @moduledoc """
  FEEL types, spelled in the semantic manifest's vocabulary.

  `kind` values are exactly RFC §5.2's; no kind is invented here.
  """

  @type t ::
          {:decimal, constraints :: map()}
          | {:string, map()}
          | {:boolean, map()}
          | {:date, map()} | {:time, map()} | {:datetime, map()} | {:duration, map()}
          | {:array, item :: t()}
          | {:map, %{fields: %{String.t() => field()}, open: boolean()}}
          | {:literal_union, [term()]}          # a normalized Ash.Type.Enum
          | {:type_ref, module :: module()}     # hoisted named type, RFC §4.1
          | {:dynamic, reason :: atom()}        # the sink; FEEL `Any`

  @typedoc "RFC §5.3: `required` is a property of the slot, never `T | nil`."
  @type field :: %{type: t(), required: boolean()}
end

defmodule AshEnterprise.Feel.Env do
  @moduledoc "What names are in scope for one expression, and what they are."

  defstruct bindings: %{}, source: nil, fidelity: :declared

  @type source ::
          {:decision_column, decision_id :: String.t(), input_id :: String.t()}
          | {:process_subject, resource :: module()}
          | {:process_routing, node_id :: String.t()}

  @type t :: %__MODULE__{
          bindings: %{String.t() => AshEnterprise.Feel.Types.t()},
          source: source() | nil,
          # `:declared` — from a typeRef or an Ash attribute.
          # `:inferred` — from an upstream decision's output type.
          # `:assumed`  — a default with no evidence; findings are info-only.
          fidelity: :declared | :inferred | :assumed
        }
end

defmodule AshEnterprise.Feel.Diagnostic do
  @moduledoc "A typing finding, addressed the way the manifest addresses things."

  defstruct [:severity, :code, :message, :path, :span, :stage, :detail]

  @type t :: %__MODULE__{
          severity: :error | :warning | :info,
          # :type_mismatch | :unknown_name | :ci_string_widened |
          # :always_null | :never_matches | :unreachable_branch
          code: atom(),
          message: String.t(),
          # DMN/BPMN element id — the existing `AshDecisions.Compiler` contract.
          path: String.t(),
          # RFC §4.5 span, or nil. See §3.
          span: span() | nil,
          stage: :parse | :type_check | :completeness,
          detail: map()
        }

  @typedoc "RFC §4.5 verbatim, including the fidelity ladder."
  @type span :: %{
          file: String.t(),
          start: %{line: pos_integer(), column: pos_integer()},
          end: %{line: pos_integer(), column: pos_integer()} | nil,
          fidelity: :exact | :start_only | :line_only | :absent
        }
end
```

The span shape is the RFC's, unchanged, including the `fidelity` ladder and the rule that
`absent` is **not an error** — it is the honest normal case when the information is not
available. That is exactly the situation here today (§3), so the ladder is not aspirational:
it describes the current state and names the rungs above it.

---

## 3. Carrying position

Three layers, each independently shippable, each raising the fidelity by one rung.

### 3.1 Element level: `absent` → `line_only`

`:xmerl`'s element records carry no position, so `AshDecisions.Tck.Xml` cannot produce one —
that is a fact about the record definition, not about the wrapper.

But `:xmerl_scan` does emit positions: it delivers `#xmerl_event{event, line, col, pos, data}`
records to an `event_fun` for every `start` and `end` event during the scan. So a span table
keyed by the element's parents-and-`pos` path can be built **during the same single parse**,
with no second pass and no change to how `Xml.parse/1`'s callers read elements:

```elixir
@spec parse(binary()) :: {:ok, element(), spans :: %{path :: [term()] => span()}}
```

This gets `start_only` for every element that has an id, which covers every `path` the compiler
already reports — so every existing `%{path:, message:}` diagnostic gains a location for free.
Getting `exact` requires the `end` event too, which the same `event_fun` receives.

Cost: one scan option and a fold. No new dependency, no second parser. This is the highest
value-per-line change in the whole document.

### 3.2 Cell level: which unary test

`AshDecisions.Feel.split_unary_tests/1` already splits a cell on top-level commas, carefully,
"so a comma inside a string literal is left alone", because a seam that split differently from
the engine "would be worse than no seam at all". It discards offsets on the way out.

Return them: `[{test :: String.t(), offset :: non_neg_integer()}]`. The regex already knows
where it cut. That turns a diagnostic on `"gold", "silvr", "bronze"` from *this cell* into
*the second test in this cell, at byte 8* — which combined with §3.1 is a real underline in the
designer.

Promoting it to public also serves `decision-validation.md` §2.1, whose recognizer must split
exactly the way the evaluator splits.

### 3.3 Expression level: FEEL offsets, upstream

Pointing inside `> 100 and < 50` needs the token stream to carry offsets.
`Boxic.FEEL.Tokenizer.tokenize/1` emits `{:identifier, "x"}`, `{:string, v}` and bare atoms
with no position, and `Boxic.FEEL.Error` has no position field. Nothing downstream can recover
what the tokenizer threw away.

The smallest upstream change that unblocks everything:

1. tokens become `{type, value, offset}` (and `{atom, offset}` for the bare ones);
2. `Boxic.FEEL.Error` gains an optional `offset` (and `length`), defaulting to `nil`.

Both are additive; existing consumers that match on two-tuples need updating, which is why it
is a real upstream conversation rather than a patch. It is the right conversation to have:
building a second FEEL tokenizer inside `ash_decisions` to get offsets would mean two
tokenizers disagreeing about a tenant-authored string, which is the failure
`AshDecisions.Feel` exists as a single seam to prevent.

Until it lands, `fidelity: :start_only` at cell granularity (§3.1 + §3.2) is the ceiling, and
the ladder says so honestly rather than the design pretending otherwise.

---

## 4. Staged rollout

The semantic-manifest RFC ships in phases because a type system that blocks on its first day
against a real corpus gets turned off. Same structure, same reason, three stages — each gated
in `AshDecisions.Config` / `AshBpmn.Config` beside the existing `feel_*` bounds, each stamping
its `stage` on every diagnostic so an operator can tell a stage-1 warning from a stage-2 one.

### Stage 0 — parse-only (mostly shipped)

*Proves:* every FEEL-bearing element is grammatical and within bounds.

Already true for literal expressions, input expressions, output entries and default output
entries. **Not** true for decision-table input entries, which are unary tests and get only
`check_size/2`.

To complete it, adopt the recognizer from [`decision-validation.md`](decision-validation.md)
§2.1: lower each input entry, and record what would not lower as an `Obligation`
(`reason: :opaque_entry`) rather than an error. No new failure mode — a document that compiles
today compiles after.

*Blocks publish:* nothing new.
*Config:* none; this is the floor.

### Stage 1 — type-check

*Proves:* every name in an expression is in scope, and every operator's operands have
compatible FEEL types.

Needs: §2.3's environment (so `ash:subject` first), §3.1's spans (so a finding is
actionable), and the accepted/normalized mapping in §2.2.

Findings, all `:warning` initially:

- `:unknown_name` — `subject.amont`. The typo that currently presents as a branch never taken.
- `:type_mismatch` — `> 1000` on a column whose `typeRef` is `string`.
- `:always_null` — an expression that can only ever evaluate to null. This is the
  `AshBpmn.Feel` gap, closed at the only place it can be closed.
- `:ci_string_widened` — §2.1's warning.

**Warnings, not errors, and that is the point.** The first run against a real corpus will
produce false positives — from `:assumed` bindings, from `dynamic` sinks that should have been
narrower, from FEEL constructs the checker has not learned. Blocking on those teaches people
to disable the checker. Promoting a code from `:warning` to `:error` is a deliberate, separate,
per-code decision made after the corpus has been measured.

*Blocks publish:* nothing, by default.
*Config:* `feel_type_check/0` — `:off | :warn | :strict`, default `:warn`.

### Stage 2 — completeness

*Proves:* a decision table covers its input space, and no two rules overlap where the hit
policy forbids it.

Depends on stage 1 and cannot precede it: completeness over a `literal_union` is only
meaningful once the column is *known* to be that enum, and `decision-validation.md` §2.2's
decidability table is a statement about types. Running completeness on untyped columns produces
exactly the obligations that document defines (`:untyped_column`), which is correct but is not
the feature.

*Blocks publish:* `:overlap` at `:error` on a `UNIQUE` table, and `:unsatisfiable` everywhere
— the two that are defects under any reading. Incompleteness stays a warning unless a tenant
opts in (`incomplete_tables/0`).
*Config:* `feel_completeness/0` — `:off | :warn | :strict`, default `:warn`.

### What each stage costs before it can start

| Stage | Prerequisite | Where |
|---|---|---|
| 0 | unary-test recognizer | `ash_decisions` |
| 1 | `ash:subject` extension element | `ash_bpmn` compiler |
| 1 | element spans from `:xmerl_scan` `event_fun` | `AshDecisions.Tck.Xml` |
| 1 | Ash type → FEEL type resolver | new, shared |
| 2 | interval/set algebra | `AshDecisions.Verifier` |
| 3 (later) | token offsets | **upstream `boxic_feel`** |

---

## 5. Integration points

| Module | Change |
|---|---|
| `AshEnterprise.Feel.{Types,Env,Diagnostic}` | **New.** §2.4. Shared by both packages through the host, since neither `ash_decisions` nor `ash_bpmn` may depend on the other — the same constraint that already forces `to_feel_value/2` to exist twice. |
| `AshEnterprise.Feel.AshTypeResolver` | **New.** Ash type → `{accepted, normalized}` FEEL pair. Delegates named types to `Ash.Info.Manifest.Generator.TypeResolver.resolve/2` rather than reimplementing hoisting (RFC §5.2). |
| `AshDecisions.Tck.Xml` | `parse/1` also returns a span table, built from `:xmerl_scan`'s `event_fun`. Element access API unchanged. §3.1. |
| `AshDecisions.Feel` | `split_unary_tests/1` public, returning offsets. Still the only caller of `Boxic.FEEL`. §3.2. |
| `AshDecisions.Compiler` | Emits `Diagnostic` alongside its existing `%{path:, message:}` errors. The old shape stays: `Definition.errors` and `ErrorsEmpty` depend on it and must not change meaning. |
| `AshDecisions.Config` | `feel_type_check/0`, `feel_completeness/0`. |
| `AshBpmn.Compiler.Graph` | Validates `ash:subject resource=`, alongside the existing `ash:decision` and `ash:signal` validation. Types gateway conditions against it. |
| `AshBpmn.Feel` | Unchanged at runtime. Its documented `:condition_null` / silent-equality gap gains a publish-time counterpart; the moduledoc is amended to point at it rather than being deleted, because the runtime gap is still real. |
| `AshEnterprise.Process.DesignerCatalogue` | Surfaces the subject resource's attributes as completions in the condition editor — the payoff a type environment makes possible. |
| `AshEnterpriseWeb.Live.Decisions.EditorLive`, `AshEnterpriseWeb.Live.Bpmn.DesignerLive` | Render diagnostics with spans. Where the design becomes useful or does not. |
| `boxic_feel` | **Upstream.** Token offsets and `Error.offset`. §3.3. |

---

## 6. Open questions

1. **Does `boxic_feel` want positioned tokens?** §3.3 is the right shape and it is a breaking
   change to an internal token format. Ask before building anything that depends on it, and do
   not build a second tokenizer if the answer is no — accept `start_only` and say so.
2. **`years and months duration` vs `days and time duration`.** Mapped to one `duration` kind
   with a constraint. FEEL treats them as genuinely different types that cannot be compared,
   so collapsing them may produce a checker that misses the one duration bug people actually
   hit. Two kinds may be the honest answer, which would be the one place this design adds to
   the RFC's vocabulary.
3. **How often is `typeRef` actually present?** Stage 1's declared half rests on it, and
   dmn-js writes it only when the author fills the field in. If real documents mostly omit it,
   stage 1 degrades to name-resolution only — still valuable (`:unknown_name` is the common
   typo) but much less than it reads. Measure against the TCK corpus and against
   `AshEnterprise.Decisions`' own documents before committing to stage 2.
4. **Multi-decision DRDs.** An upstream decision's `output/@typeRef` types a downstream
   decision's input — that is `fidelity: :inferred` and the compiler already has the
   requirement edges and evaluation order. Not designed here; it is the obvious stage-1.5.
5. **Does the type environment belong in the graph snapshot?** Storing the resolved environment
   in `Definition.graph` would make a published definition carry the types it was checked
   against, which is exactly the argument the snapshot already makes for storing the engine
   version. It also means the graph changes when a *resource* changes, which no other part of
   the snapshot does. Unresolved, and it is the interesting question of the three.
6. **`ash:subject` on an existing corpus.** Every diagram without it types as `Any` and is
   unchecked — correct, and it means adoption is a per-diagram migration nobody is obliged to
   do. Whether a tenant should be able to *require* it for new publishes is a policy question,
   not a typing one.
