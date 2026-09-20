# Review: `Ash.Info.Manifest.Semantic` against semantic-manifest-v0

| | |
|---|---|
| **Reviewed** | `feature/manifest-semantic-export` @ `11e0c8ccb` in `/home/lukegalea/ast-forks/ash` |
| **Against** | `docs/rfc/semantic-manifest-v0.md` (rev 2), `docs/rfc/semantic-manifest-v0.schema.json`, `docs/rfc/fixtures/ash_enterprise_accounts_team.manifest.json` |
| **Method** | Source read + empirical: built the branch (Elixir 1.19.5 / OTP 27), ran the 38 tests (pass), emitted documents for all **68** Ash resources reachable from the `:ash` test app, and validated every document with a real JSON Schema **draft 2020-12** processor (`python-jsonschema` 4.19.2) rather than the branch's hand-rolled checker. |
| **Date** | 2026-09-20 |

## Verdict: **fix first**

The shape is right — this is a faithful reading of the RFC's structure, the id grammar,
the accepted/normalized split and the §8 sink discipline, and it is visibly built from the
RFC rather than around it. But four defects are disqualifying as they stand, and three of
them are load-bearing claims in the implementer's own summary:

- the emitter **crashes** on a common attribute shape (`default: Decimal.new(…)`, `default: ~D[…]`);
- `sensitive?: true` values are **emitted verbatim** — §8's one security prohibition is unimplemented;
- `hashes.content` **is** span-dependent, the exact opposite of the claim and of RFC §4.4,
  and the test that "proves" otherwise is a tautology;
- **10 of 68** emitted documents **fail the RFC schema** under a real 2020-12 validator, so
  "84/84 schema-valid" is an artefact of the structural checker, not a property of the output.

None of these is architectural. All are localized. The soundness findings (S5–S7) are the
ones worth arguing about before landing, because they are the RFC's declared worst failure
mode and the current tests actively lock the narrowing in.

---

## Findings

### S1 — Emitter crashes on any non-`Enumerable` struct literal `[blocker · correctness]`

`Canonical.encode_term/1`'s first clause is `%{} = map`, which matches **every struct**, and
then `Enum.map`s it.

- `lib/ash/info/manifest/semantic/canonical.ex:56-63`
- reached from `lib/ash/info/manifest/semantic/fields.ex:673` (`literal_term/1`'s catch-all
  keeps the raw term as `"value"`)
- and from `lib/ash/info/manifest/semantic/symbols.ex:429-435` (`plain_value/1` deliberately
  **excludes** `Date`/`Time`/`DateTime`/`NaiveDateTime`/`Decimal` from `bounded_inspect`, so
  they fall through to `plain_value(value), do: value`)

Reproduced twice, on a three-attribute resource:

```
attribute :ratio, :decimal, default: Decimal.new("1.5")
** (Protocol.UndefinedError) protocol Enumerable not implemented for Decimal (a struct)
    (ash) lib/ash/info/manifest/semantic/canonical.ex:59: Canonical.encode_term/1

attribute :started_on, :date, default: ~D[2024-01-01]
** (Protocol.UndefinedError) protocol Enumerable not implemented for Date (a struct)
    (ash) lib/ash/info/manifest/semantic/canonical.ex:59: Canonical.encode_term/1
```

`attribute :amount, :decimal, default: Decimal.new(0)` is not exotic. It takes down
`mix ash.manifest.dump --semantic` for the whole app.

Two separate bugs, both need fixing: `encode_term` must not treat a struct as a JSON object
(guard `when not is_struct(map)`, with an explicit struct clause), and `literal_term/1` /
`plain_value/1` must not emit raw structs (§8.6: "any struct whose internal representation
is private"). Note that even if `encode_term` is fixed, `Jason.encode!` in the mix task
(`lib/mix/tasks/ash.manifest.dump.ex`, `write_json/2`) and `Canonical` disagree about how a
`Date` renders — Jason emits `"2024-01-01"`, `Canonical` would emit a struct map — so
`hashes.manifest` becomes unverifiable by a consumer. Fix at the emitter, not the encoder.

### S2 — `sensitive?: true` values are not redacted `[blocker · §8.7 security]`

RFC §8, prohibition 7, normative: "Emitters MUST treat … any `Ash.Resource.Attribute` or
`Argument` with `sensitive?: true`, as value-redacted: the type is emitted, the default and
any literal are replaced with `{"kind":"dynamic","name":"Dynamic","reason":"redacted_sensitive"}`."

`grep -r redacted_sensitive lib/ash/info/manifest/semantic*` → no hits. The schema defines
the reason (`semantic-manifest-v0.schema.json:551`); the emitter never produces it.
`put_public_and_sensitive/2` (`fields.ex:599-604`) records the *flag* and then
`default_value/1` (`fields.ex:52`, `641-673`) serializes the value regardless.

Demonstrated:

```elixir
attribute :api_key, :string, sensitive?: true, default: "sk-live-DO-NOT-LEAK"
```
```
ATTR api_key sensitive=true
  default=%{"type" => %{"kind" => "literal", "value" => "sk-live-DO-NOT-LEAK"},
            "value_repr" => "\"sk-live-DO-NOT-LEAK\""}
```

Manifests are written to `_build/` and are explicitly designed to be shipped over stdio to
another node and cached across machines. Add redaction on `attribute` / `argument` /
`section` option paths, and on `constraints` for a sensitive slot. Also missing: §8.7's
"any option whose schema marks it `sensitive?`/`private?`" — section options
(`symbols.ex:242-271`) are `bounded_inspect`'d wholesale with no sensitivity check at all.

### S3 — `hashes.content` changes when a declaration moves `[blocker · §4.4]`

RFC §4.4: "Spans are excluded from `content` deliberately: moving a declaration down a file
must not invalidate a consumer's semantic cache."

`content_payload/1` (`symbols.ex:120-121`) drops `hashes`, `span`, `property_spans` — but
**not** `provenance`, and `Provenance.for_entity/3` embeds a full span in every `declared`
step (`provenance.ex:320`, `provenance.ex:326`). So the span survives into the content hash
by a second route.

Measured, on the branch's own `Ash.Test.SemanticManifest.Project`, attribute `:id`:

```
content as emitted    : sha256:5d338a3e656b47e0fa5e3136f4b06222
same symbol, provenance[0].span.start.line 39 -> 999
                      : sha256:bee23341b116c9b992cc45433f8fc354
```

Adding one blank line above an attribute invalidates every downstream symbol's semantic
cache. That defeats the stated purpose of the three-digest scheme.

**The test that covers this is a tautology.** `test/ash/info/manifest/semantic_test.exs:168-185`
("content digest excludes spans: moving a declaration must not change it") asserts
`digest(Map.drop(symbol, ["span","property_spans","hashes"])) == symbol["hashes"]["content"]`
— which is a verbatim re-execution of `content_payload/1`. It moves nothing. It would pass
for *any* definition of the content payload.

Fix: strip `span` from each provenance step before hashing content (or hash a
provenance projection of `{stage, by, inferred}` only).

### S4 — `ash_type` is emitted as an object for array types; 10/68 documents fail the real schema `[blocker · schema conformance]`

`fields.ex:682`:

```elixir
defp ash_type_string({:array, inner}), do: %{"kind" => "array", "of" => ash_type_string(inner)}
```

The schema types `ash_type` as `anyOf[moduleName, atomName]` — both **strings** —
on `symbolAttribute`, `symbolArgument`, `symbolCalculation` and `symbolAggregate`. An object
fails every `oneOf` branch of `#/$defs/symbol` (the branch is pinned by `kind: {const: …}`,
and `symbolUnknownKind` is excluded by its `not: {enum: [known kinds]}`), so **zero** branches
match, and `unevaluatedProperties: false` then reports the whole body as unevaluated.

Empirically, over the 68 resources reachable from the `:ash` test app:

```
docs: 68   invalid: 10
  Ash.Test.Manifest.AggregateHolder, .InputParsing.Resource, .OrgTodo, .Post, .Todo,
  .TodoContent.ChecklistContent, .TodoMetadata, Ash.Test.SemanticManifest.Project, …
```

Patching only `ash_type` to a string in-memory and re-validating: **0 invalid**. So this is
the single conformance defect in the corpus — one line, but it invalidates the headline
claim. The branch's structural checker never type-checks `ash_type` at all
(`test/support/semantic_schema_check.ex:367-369` lists it as an *allowed key* and stops
there), which is why 38 tests pass on output the schema rejects.

Decide which side moves: emit `"{:array, Ash.Type.String}"` as a string, or widen the
schema's `ash_type` to admit `{kind, of}`. The RFC fixture uses a plain string, so the
emitter is the thing that is wrong.

### S5 — Enum `accepted` narrows: `Ash.Type.Enum` casting is case-insensitive and overridable `[high · §5.3 soundness]`

`type_terms.ex:73-92` builds the accepted term for an enum as a union of
`literal_union(values)` and `string` with `constraints.one_of = Enum.map(values, &to_string/1)`.

`Ash.Type.Enum`'s generated `match/1` (`lib/ash/type/enum.ex:334-350`) downcases both sides
before comparing, and falls back through `to_string/1` on arbitrary terms. So `"DRAFT"`,
`"Draft"` and `"dRaFt"` all cast successfully and **none of them is in the emitted
`one_of`**. Worse, `match/1` is `defoverridable` (`enum.ex:362`) and the module's own
moduledoc example (`enum.ex:50-51`) defines an *alias* — `match(:half_empty) → {:ok, :half_full}` —
a value that is not in `values` at all and that no static projection can see.

RFC §5.3, normative: *"an emitter must never narrow. If it cannot prove the narrow type it
must emit the wider one, and `dynamic` is always a legal answer. A false `literal_union` is
worse than an honest `dynamic`, because it turns a working program into a reported error."*
This is precisely that case.

Compounding it, `type_terms.ex:61-63` documents a behaviour the code does not have: "the
atom form, the exact string form, **and a case-insensitive string form**". Only the first
two are emitted.

And `semantic_test.exs:258` asserts the narrow set (`one_of == ["draft","active","archived"]`),
so the defect is pinned by a passing test.

Minimum fix: widen `string_form` to a plain `string` (or `dynamic(reason: "enum_cast")`) when
`match/1` is overridden, and carry the case-insensitive set otherwise — e.g.
`constraints: {one_of_ci: [...]}` — rather than an exact `one_of` the runtime does not enforce.

### S6 — `accepted_term/1` only widens at the top level `[high · §5.3 soundness]`

`type_terms.ex:71-130` pattern-matches on `enum`, `type_ref` and `uuid` at the root of a term
and returns `term` unchanged for everything else (`:130`). It never recurses into
`item_type`, `fields`, `members`, `element_types` or `value_type`.

Consequences, all narrowing:

- `{:array, TeamType}` → `accepted == normalized == array(type_ref(TeamType))`. At runtime
  `["owner"]` casts fine; the manifest says only atoms are accepted.
- `attribute :settings, :map, constraints: [fields: [...]]` — `accepted` inherits Ash's
  closed `fields` with no `open: true` and no string-key allowance, though `cast_input`
  takes string keys.
- Embedded resources: same — `accepted` is the normalized struct shape.
- A `type_ref` to a `NewType` is replaced by `to_term(resolve(unwrapped))` (`:104-109`),
  i.e. the *normalized* term of the subtype, not `accepted_term/1` of it. A NewType over an
  enum therefore loses the string form entirely.

Either recurse, or fall back to `dynamic` for composite kinds. Emitting `normalized` as
`accepted` is exactly the false precision §5.3 forbids.

### S7 — Code-interface and action return types are narrowed `[high · §5.3 soundness]`

RFC §5.3 spells out `returns`: "a `result` whose `ok` is the resource struct (create/update),
an `array` of it, a `page`, `:ok`-only for destroy, or the declared generic-action return type."

`Symbols.success_error_terms/3` (`symbols.ex:716-775`) ignores the action type entirely and
always emits `resource_term(ctx)` — the bare struct — as the `ok` value:

- A non-`get?` read interface (`define :list_projects, action: :read`) is documented as
  returning `{:ok, %Project{}}`. It returns `{:ok, [%Project{}]}`.
  The test corpus has no such interface, so nothing catches it.
- `:subject` variants (`input_to_create/2`, `changeset_to_update/2`) are documented as
  returning `{:ok, %Project{}}`. They return an `%Ash.ActionInput{}` / `%Ash.Changeset{}`
  directly, not a result tuple. Verified in the emitted `Project` document:
  `input_to_create/2 variant=subject success={tuple, [literal "ok", resource Project]}`.
- Paginated reads: `Fields.returns/2` handles `page` correctly (`fields.ex:494-509`), but the
  code-interface path does not reuse it.

Separately, the `error` arm is hard-coded to `Ash.Error.Invalid` in both places
(`symbols.ex:759-769`, `fields.ex:530-536`). Actions also return `Ash.Error.Forbidden`,
`Ash.Error.Framework`, `Ash.Error.Unknown` and `Ash.Error.Query.NotFound`. A consumer
branching on the declared error type will mis-handle a forbidden.

Route the code-interface `success` through the same `Fields.returns/2` logic, and widen the
error arm to a union or `Ash.Error`.

### S8 — `hashes.inputs` does not cover the files that actually generate the symbols `[high · §7.3]`

RFC §7.3 names two deliberate properties. Neither holds.

**Injector files.** *"`files[]` includes injector files. Editing
`lib/ash_enterprise/platform/resource.ex` invalidates the manifest of every resource that
`use`s it. Without this the cache is wrong in exactly the case that matters most in this
codebase."*

`Semantic.files/2` (`semantic.ex:328-355`) derives injector entries **from span files** —
any span file that is not the declaration file. But RFC §4.6 states that a macro-injected
entity's anno "points at the `use` site, because `macro_env_anno/2` uses `env.file`/`env.line`".
The use site *is* the module's own file. So the injector's source never appears in any span,
is never added to `files[]`, and editing it does not change `hashes.inputs`. The named
motivating case is unprotected. Confirmed on the emitted documents: every one of the 68 has
exactly one `files[]` entry, role `declaration`.

**Extension digests.** *"`extensions_digest` uses BEAM digests, not versions. A locally
modified extension in `deps/` or in-project changes behaviour without changing a version
string."*

`extension_modules/1` (`semantic.ex:378-383`) reads `module_info(:attributes)[:extensions]`,
which for a resource is:

```
[Ash.DataLayer.Ets, Ash.Policy.Authorizer, Ash.Resource.Dsl]
```

The modules that actually add entities are separate BEAMs —
`Ash.Resource.Transformers.*`, and in `ash_enterprise`,
`AshEnterprise.Platform.Transformers.AddSystemAttributes`. Editing a transformer changes the
manifest's contents and leaves `hashes.inputs` identical. A language server keyed on
`hashes.inputs` will serve stale symbols after exactly the edit that changes them most.

Fix: walk each extension's `transformers/0` and `verifiers/0` into the digest, and add the
`__using__` injector by resolving `dsl[:persist][:env].module` (or the proposed attribution
hook) rather than by scanning spans.

### S9 — `transformer_added` is asserted from absence, and mislabels `[high · §4.6]`

`Provenance.for_entity/3` (`provenance.ex:302-335`) is a three-way `cond` whose first branch is
`is_nil(span) -> transformer_added`. The RFC's shipped heuristic is narrower: *"entity has no
anno **and the section is not in the module's own file list**, therefore `transformer_added`"*.
The second conjunct is dropped.

Two observed failure modes:

1. **`debug_info` off ⇒ every symbol is labelled `transformer_added`.** §2.3 and §4.5 are
   explicit that annotations exist only under `debug_info` and that a document with every
   span `null` is *legal*. Under that legal document the emitter asserts, for every
   hand-written attribute, action and policy in the file, that a transformer added it and it
   does not know which. `maybe_diagnose_spans/2` (`semantic.ex:453-477`) already computes the
   "no spans anywhere" signal for the `toolchain.debug_info` field; the provenance builder
   never consults it. At minimum, fall back to a single `{"stage": "declared", "inferred": true}`
   or drop the step when the whole document is span-less.

2. **User-written DSL labelled as transformer output.** In the branch's own fixture, the
   `destroy` action — written by the user as `defaults [:read, :destroy, …]` — is emitted as
   `transformer_added, by: null, inferred: true`, and `semantic_test.exs:213-228` locks that
   in as correct. The `actions` section carries a `section_anno`; a heuristic that consults it
   could say "declared in this file, materialised by a transformer" instead of pointing the
   user at nothing.

Beyond the mislabel, the provenance layer answers none of RFC goal #2 ("provenance that points
at user code"):

- `by` is `nil` on **every** step except the synthetic `Ash.CodeInterface` one
  (`provenance.ex:310, 320, 328`).
- `macro_injected`, `fragment`, `extension_patch`, `option_default` and `auto_set` are never
  emitted. Everything with a span is `declared`; everything without is `transformer_added`.
  A value filled from a `Spark.Options` `:default` is indistinguishable from one the user typed.

The RFC accepts `by: null` for the transformer case pending the Spark hook. It does not accept
collapsing five distinct stages into two, and `option_default` in particular is derivable today
from the extension's schema.

### S10 — The emitter creates atoms `[medium · §8.3]`

RFC §8, prohibition 3, closing sentence: *"Emitters MUST NOT create atoms while emitting either."*

Three sites in `symbols.ex`:

- `:513` — `:"#{interface.name}!"`
- `:588` — `:"#{subject}_to_#{interface.name}"`
- `:571-575` — `predicate_base/1` calls `String.to_existing_atom/1` and then, in the `rescue`,
  falls back to **`String.to_atom/1`**. That one genuinely mints a new atom on the failure path.

All three are string-interpolation atom construction on a per-emit basis. Build the names as
binaries; nothing downstream needs them as atoms (`Atom.to_string/1` is called on them two lines
later at `:523`).

### S11 — Policy check options leak raw terms `[medium · §7.2 / §8.6]`

`plain_value/1` (`symbols.ex:426-435`) routes every struct to `bounded_inspect` **except**
`Date`, `Time`, `DateTime`, `NaiveDateTime` and `Decimal`, which fall through to the identity
clause at `:435` and land in the document as raw structs — the same crash path as S1, reached
through `policy.checks[].opts_repr` instead of `attribute.default`.

Floats take the same route: `plain_value/1` has no float clause, so `check MyCheck, ratio: 0.5`
puts a bare `0.5` in the document. §7.2 rule 4 requires floats to be carried as a string.
`TypeTerms.sanitize_value/1` gets this right (`type_terms.ex:289`); `plain_value/1` is a second,
divergent copy of the same responsibility. Delete it and call `sanitize_value/1`.

### S12 — The module-scoped `types` table is incomplete `[medium · §4.1]`

`named_type_table/1` (`semantic.ex:277-287`) reduces over `symbol["type"]` only. It does not
walk `accepted_input`, `normalized_input`, `returns`, `metadata`, `default`, or the
code-interface `params`/`success`/`error` slots — even though `field_relations`
(`semantic.ex:176-191`) does walk `default`, so the two disagree.

Scanned across the 68-document corpus, two documents carry `type_ref`s with no table entry:

```
Ash.Test.Manifest.InputParsing.Resource
  -> ProcessProfileResult   (action:process_profile/returns/ok)
Ash.Test.Manifest.Post
  -> InputParsing.Options            (action:get_custom_metadata/returns/ok)
  -> InputParsing.PreferencesKeyword (action:update_internal_code/metadata/type)
  -> Types.EmailString               (action:update_internal_code/normalized_input/fields/type)
```

§5.2 makes this schema-legal — a `type_ref` not in the local table "is resolved against the
app-scoped Ash manifest". But `mix ash.manifest.dump --semantic` emits *only* per-module
documents and **no** app-scoped manifest (see S13), so nothing resolves them. The
corresponding `references_named_type` relations are missing too.

### S13 — Coverage and CLI gaps `[medium]`

- **Domain-rooted code interfaces are not emitted at all.** RFC §4.3 makes the domain the
  owner of generated function ids, and its worked example is
  `ash:v0:AshEnterprise.Accounts#code_interface/create_team!/3`. The domain branch
  (`semantic.ex:243-261`) emits a single shell symbol of kind `"domain"` — which is not one of
  the RFC's ten kinds and falls through to `symbolUnknownKind` — and never reads the domain's
  `resource … do define … end` blocks. Resource-level `code_interface` is covered; the RFC's
  own example is not.
- **`can_*` interfaces are dropped.** `code_interface_symbols/1` defaults `functions` to
  `[:subject, :can, :can?, :action, :action!]` (`symbols.ex:466`) and then discards `:can` and
  `:can?` in the `_other -> []` clause (`:483-484`). RFC §2.6 enumerates them as derivable and
  they are what a completion consumer needs for conditional-render call sites.
- **`--semantic` replaces the app manifest rather than adding to it.** RFC §3.6 frames the flag
  as "`mix ash.manifest.dump --semantic` **adds** spans, ids, hashes, provenance". The task
  branches to `generate_semantic/3` and never emits the app-scoped document, so `resources`,
  `entrypoints` and `filter_capabilities` are simply gone in `--semantic` mode, and §3.4's
  "the two scopes compose" is not reachable from the CLI. (`Generator.generate(semantic: true)`
  *does* compose, under `custom[:semantic]` — the task should use it.)
- **`--per-module` is parsed and ignored**, and `generate_semantic/3` drops the
  `include_private_*?` options the moduledoc advertises (`semantic.ex:61-66`) — it calls
  `generate_for_app/2` with only `:modules`.
- **`property_spans` is populated for 19 of 37 symbols** on the fixture resource, and every
  span on this toolchain is `fidelity: "line_only"` (Spark records `location: 41`, a bare
  integer). That is Spark's limit, not the emitter's, but the RFC's `exact` case is
  currently unreachable and the "underline `allow_nil? false`, not the whole block" use case
  gets line granularity only. Worth stating in the PR rather than leaving a reviewer to find it.

### S14 — Smaller things `[low]`

- `required_inputs` (`fields.ex:470-480`) reads only `{:attributes_to_require, _}` and so omits
  **required arguments**, while `accepted_input.fields[].required` includes them. Two views of
  the same fact that disagree. RFC §5.3 calls `required_inputs` "the convenience view" of the
  required set, not of the required-attributes subset.
- `accepted_attribute_presence/3` (`fields.ex:428-434`) computes `required?` for creates without
  filtering writable/non-generated attributes, but `{:attributes_to_require, _}` does
  (RFC §2.5) — a second source of the same disagreement.
- `accepted_attribute_inputs/3` wraps the whole `Enum.flat_map` in `rescue ArgumentError -> []`
  (`fields.ex:413-414`). If one `String.to_existing_atom/1` ever failed, **every** accepted
  attribute for that action would vanish silently from both contracts. As written the round-trip
  (`accept_names/1` stringifies atoms at `:332-337`, this restringifies them at `:395`) can never
  fail, so the rescue is dead code guarding a pointless conversion. Delete both.
- `files/2` emits `%{"path" => "unknown", "digest" => digest("unknown"), "role" => "declaration"}`
  when the source is unknown (`semantic.ex:335`). A synthetic path that passes the schema's
  `^[^/].*$` and silently pins the invalidation key to a constant.
- `Spans.normalize_file/1`'s `relative_fallback/1` (`spans.ex:262-270`) ends with
  `String.trim_leading(path, "/")` when no `lib|test|apps|priv` segment is found. That yields
  `home/lukegalea/.cache/...` — schema-legal (`^[^/].*$`), but it is still the build machine's
  absolute layout with one character removed, which is what §4.5 and §8.8 exist to prevent.
  Emit `nil` instead. The `path == :badpath` branch above it (`spans.ex:192`) is dead —
  `Path.relative_to_cwd/1` returns a binary.
- `Canonical.encode_key/1` maps `:foo` and `"foo"` to the same key (`canonical.ex:88-90`); a map
  holding both would canonicalize to duplicate JSON keys.
- `union/2` (`type_terms.ex:184-186`) records `constraints.original_kind` — except on the
  `type_ref → enum` path (`:98-102`), where the synthetic term has no `constraints` key so
  `Map.update/4` installs the default `%{}` and the annotation is lost.
- `toolchain_digest` uses `"emitter" => "ash.manifest.dump --semantic"` (the emitter *name*,
  `semantic.ex:404`) where §7.3 specifies `emitter.version`. Harmless today, wrong when the
  emitter version is the thing that changed.

---

## Schema validator gap — what the structural checker misses

`test/support/semantic_schema_check.ex` is an honest reimplementation of the schema's *key
sets*, and its moduledoc says so. What it does not do is validate **values**, and that is where
the real schema bites. Concretely, running both over the same 68 documents:

| | structural checker | `Draft202012Validator` |
|---|---|---|
| invalid documents | 0 | **10** |

The gap classes:

1. **Property value types are unchecked.** `ash_type` appears only in the allowed-key lists
   (`:367-388`); its `anyOf[moduleName, atomName]` is never applied. That is the entire 10/68
   failure (S4). The same is true of `destination`, `calculation_module`, `target_module`,
   `action_ref.*` and every other `moduleName`-typed leaf outside the handful the checker
   explicitly regexes.
2. **`oneOf` semantics are not modelled.** The checker dispatches on `kind` with a `cond`
   (`:169-174`). The schema requires *exactly one* branch to match, and a branch matches only
   if all of its `required` and property constraints hold. A symbol that fails its own branch
   falls through to zero matches in the real validator; in the checker it is simply checked
   against the branch's key list. This is what let an object-valued `ash_type` through.
3. **`unevaluatedProperties: false` is approximated by a hand-maintained union.** `@base_keys ++
   attribute_body()` etc. (`:396-414`) is a copy of the schema's property names. It is currently
   accurate, but it is a second source of truth that will drift from
   `semantic-manifest-v0.schema.json` the first time a property is added on either side, and
   nothing detects the drift.
4. **`type` is under-constrained.** `type_term/2` (`:278-332`) implements five of the schema's
   conditionals but never enforces `required: ["kind","name"]` — a type term with a `nil` or
   missing `name` passes the checker and fails the schema. `to_term/1` writes
   `"name" => type.name` unconditionally (`type_terms.ex:36`), so a resolver that yields
   `name: nil` produces a document the tests call valid.
5. **`namedType` is not required to carry a string `module`.** `named_types/2` (`:153-158`)
   calls `module_name/3`, which is nil-tolerant in several of its siblings; the schema's
   `allOf: [type, {required: ["module"]}]` is not reproduced.
6. **Patterns on `relation.from`/`to`, `diagnostic.symbol`, `provenanceStep.by`** are checked
   loosely or not at all.

The right answer is not a better hand-rolled checker. `mix ash.manifest.dump --semantic` already
writes JSON to disk; run a real 2020-12 validator over that output in CI (any language —
`check-jsonschema`, `ajv-cli`, `python-jsonschema` — none of which becomes a Hex dependency of
`ash`). RFC §10's remaining exit criterion is literally "a validator in CI". Keep the structural
checker as a fast in-suite smoke test if you like, but it must not be the thing the conformance
claim rests on.

---

## What to add to tests

Ordered by how much a passing version would have caught above.

1. **A real JSON Schema 2020-12 validation step in CI** over the emitted `_build/*/spark_manifests/*.json`,
   not the in-suite structural checker. (Catches S4 and the whole class.)
2. **Make the content-hash test actually move a declaration.** Emit the document; construct a
   second symbol map with `span.start.line` and `provenance[].span.start.line` shifted by N;
   assert `hashes.content` is unchanged and `hashes.identity`/`shape` are unchanged. Delete the
   current tautology at `semantic_test.exs:168-185` — do not keep both. (S3)
3. **`hashes.inputs` recomputation, from scratch, per §7.3.** Independently compute
   `sha256(canonical({files: [...], extensions: …, toolchain: …}))` in the test and compare;
   then mutate a declared file and a transformer module and assert `inputs` changes for each.
   The present test (`:187-201`) only regex-matches the digest. (S8)
4. **`hashes.manifest` round-trip through `Jason`**, not through the in-memory map:
   `Jason.decode!(Jason.encode!(doc)) |> Map.delete("hashes") |> Canonical.digest()` must equal
   `doc["hashes"]["manifest"]`. Add fixture attributes with a float, a `Decimal` default, a
   `~D[]` default and a `~r//` constraint. (S1, S11)
5. **A sensitive-value fixture.** `attribute :api_key, :string, sensitive?: true, default: "…"`,
   a `sensitive?: true` argument, and a sensitive section option; assert every value slot is
   `{"kind":"dynamic","reason":"redacted_sensitive"}` and that the literal string appears
   **nowhere** in `Jason.encode!(doc)`. (S2)
6. **A `debug_info: false` document.** Assert `toolchain.debug_info == false`, `diagnostics` is
   populated, every `span` is `null` — and that no symbol claims `transformer_added` purely
   because spans are missing. (S9)
7. **Enum accepted-surface tests that exercise the runtime.** For each `values` entry assert
   `Ash.Type.cast_input(Status, String.upcase(v))` succeeds and that the emitted `accepted` term
   admits it. Add a fixture enum with an overridden `match/1` alias and assert the emitter falls
   back to a wider term rather than a `one_of`. (S5)
8. **A composite accepted-type test:** `{:array, Status}`, a `:map` with `fields` constraints,
   and an embedded resource. Assert `accepted != normalized` (or that `accepted` is `dynamic`)
   for each. (S6)
9. **A non-`get?` read code interface** (`define :list_projects, action: :read`) and a paginated
   one; assert `success.ok` is an `array`/`page`, not the bare resource. Assert a `:subject`
   variant is not a result tuple. Assert the error arm admits `Ash.Error.Forbidden`. (S7)
10. **A `use`-macro injector fixture** — a module whose `__using__` adds attributes — and assert
    its source file appears in `files[]` with `role: "injector"`, and that editing it changes
    `hashes.inputs`. (S8)
11. **Property-based or fixture sweep over `Ash.Type` literals**: for every scalar Ash type,
    build an attribute with a literal default, emit, `Jason.encode!`, and canonicalize. Any
    struct or float that survives to the document fails the test. (S1, S11)
12. **A types-table completeness invariant**: every `type_ref` with a `module` anywhere in the
    document must have a matching `types[]` entry, and a `references_named_type` relation. (S12)
13. **Atom-table assertion**: snapshot `:erlang.system_info(:atom_count)` around
    `generate_for_app/2` and assert it does not grow. (S10)
14. **A domain-rooted code-interface fixture** with `resource X do define :create_x end` in the
    domain, asserting the RFC §4.3 id `ash:v0:<Domain>#code_interface/create_x!/<arity>` and the
    `implements_action` relation into the resource's manifest. (S13)
