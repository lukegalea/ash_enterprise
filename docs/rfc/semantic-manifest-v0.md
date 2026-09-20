# RFC: Spark/Ash Semantic Manifest, v0

| | |
|---|---|
| **Status** | Draft — for review |
| **Revision** | 2 — rebased on the existing `Ash.Info.Manifest` (see §3 and the changelog in §11) |
| **Work item** | FIRST-1 (Ash Semantic Tooling, Phase 0) |
| **Target** | `spark` (core), `ash` (projection), tooling consumers |
| **Extends** | `Ash.Info.Manifest`, `schema_version` `"1.0.0"` (`ash` `lib/ash/info/manifest.ex`) |
| **Grounded against** | `spark` v2.7.3, `ash` v3.33.5 (vendored read-only clones under `.slim/clonedeps/repos/`) |
| **Artifacts** | `docs/rfc/semantic-manifest-v0.schema.json`, `docs/rfc/fixtures/ash_enterprise_accounts_team.manifest.json` |
| **Supersedes** | nothing. It does not supersede `Ash.Info.Manifest` either — it layers on it. |

---

## 0. Framing for maintainers

**The short version: this is your manifest, plus source maps and stable ids.**

Ash already ships `Ash.Info.Manifest` — a versioned IR of the app's Ash surface
(`schema_version "1.0.0"`), with structs for resources, actions, fields, arguments, relationships
and types, a reachability-driven generator, lookup maps, a JSON serializer, and
`mix ash.manifest.dump`. An earlier draft of this RFC did not account for it and proposed a
parallel document. That was wrong, and this revision withdraws it. §3 is a field-by-field mapping
of what `Ash.Info.Manifest` already covers against what is genuinely missing, and §11 lists every
place the schema was collapsed onto Ash's existing shapes rather than duplicating them.

What is missing is not a description of the runtime surface — Ash has that. What is missing is
everything a tool needs to point back at *source*:

| Missing today | What it unblocks |
|---|---|
| Source spans on every declaration and option | go-to-definition, hover, underlining one option rather than a block |
| Stable, structural symbol ids | cross-tool references that survive a recompile; agent transcripts; editor state |
| Per-symbol content/shape/identity digests | incremental re-indexing; "did this action actually change?" |
| Provenance chains | telling a user *which* `use` macro or transformer put a policy there |
| An accepted-vs-normalized type split | honest completion at a generated boundary that casts its input |

All five are additive. Nothing here asks Spark or Ash to change an existing public API, a struct
shape, or a compilation order. Concretely:

- No existing field is removed or repurposed. `Ash.Info.Manifest.JsonSerializer`'s output remains
  byte-identical for a caller that does not opt in.
- The span/provenance data is *derived* from state Spark already holds at
  `Module.get_attribute(mod, :spark_dsl_config)` — including annotations Spark already records
  (§2.3). It is a projection, not a second source of truth.
- Emission is opt-in: a flag on the existing task (`mix ash.manifest.dump --semantic`) for Ash
  apps, a sibling task (`mix spark.semantic`) for non-Ash Spark DSLs, and
  `config :spark, :semantic_manifest, emit: true` for emit-on-compile. A project that never opts
  in pays nothing at compile time. §3.6 works this through.
- Two small *hooks* are proposed inside Spark (§6.3, §6.4). Both are optional keyword arguments on
  existing functions and both are no-ops when absent. Everything else in this document is a
  consumer-side derivation of data Spark or Ash already stores.
- Where a field cannot be produced from anything Spark or Ash stores today, it is tagged
  **`provenance: proposed`** inline and is `null`/absent in a conforming v0 emitter until the
  corresponding hook lands.

The motivating problem is in `docs/Making Ash Spark First-Class in Elixir Tooling.md`: four
independent consumers — Expert completion, an MCP tool for coding agents, a Clarity graph
importer, and a documentation/interface exporter — are each about to re-derive Ash semantics by
loading modules and introspecting them. That is four copies of the same fragile coupling that the
existing ElixirSense plugin already demonstrates
(`.slim/clonedeps/repos/ash-project__spark/lib/spark/elixir_sense/plugin.ex`, 1304 lines, which
probes three different host behaviours with `Code.ensure_compiled/1` and rescues everything to
`:ignore`). `Ash.Info.Manifest` is already most of the artifact those four consumers should be
coding against. This RFC is about making it addressable back to source.

---

## 1. Goals and non-goals

### 1.1 Goals

0. **Reuse, not replace.** Where `Ash.Info.Manifest` already models a concept, use its shape and
   its property names. Every divergence must be justified by something spans-and-source-identity
   need that a runtime API description does not. §3 is the audit; §11 is the list of collapses.
1. **One serializable contract.** A JSON document per DSL module that describes the module's
   declarative surface without executing it, sufficient for completion, hover, navigation,
   diagnostics, and agent queries.
2. **Provenance that points at user code.** When a policy is injected by a `__using__` macro and an
   attribute is added by a transformer, the manifest says so, and says where the user can go to
   change it. Framework-shaped diagnostics are the single largest usability complaint about
   generated-code ecosystems.
3. **Cheap, correct invalidation.** A consumer must be able to decide "is my cached manifest still
   valid?" without recompiling or loading the module.
4. **Honest typing.** Distinguish what a generated boundary *accepts* from what it *normalizes to*.
   Refuse to claim precision that Ash's casting layer does not actually provide.
5. **Portability.** The manifest must survive being written to disk, sent over stdio to a language
   server in a different BEAM node, or handed to a process that has never loaded the resource.
6. **Joinability.** A consumer holding an `Ash.Info.Manifest` JSON dump and a v0 document for the
   same app must be able to join them without heuristics. §3.5 defines the join keys.

### 1.2 Non-goals for v0

- **Not a second manifest.** v0 is not an alternative to `Ash.Info.Manifest` and does not restate
  its filter/sort capability catalog, its reachability rules, or its app-level entrypoint list. A
  consumer that only wants the runtime API surface should keep using `mix ash.manifest.dump` and
  never read a v0 document at all.
- **Not a type checker.** The manifest carries a type *vocabulary*; it does not decide
  assignability. Consumers do that.
- **Not a replacement for `Ash.Resource.Info`.** In-VM callers with the module loaded should keep
  using the Info modules. The manifest exists for callers who cannot or should not load it.
- **Not an expression model.** Ash filter/calculation expressions (`expr(team_type == :owner)`) are
  carried as an opaque node plus a source span in v0. Modelling the expression algebra is Phase 6
  work (see the roadmap in the architecture doc) and is deliberately deferred.
- **Not rename tracking.** See §4.4 — v0 models a rename as delete + create and gives consumers a
  `shape_hash` so they can heuristically pair them if they want to.
- **Not a compile-time guarantee of purity.** `Spark.analyze/3` (pure analysis mode) is a separate,
  later proposal. v0 emits the manifest from a *compiled* module, where the transformers have
  already run. This is the conservative ordering: get the data format agreed before arguing about
  sandboxing.

---

## 2. What Spark and Ash actually store today

Everything in §4–§8 is a projection of the following. Citations are to the vendored clones.

### 2.1 DSL state

A compiled Spark module carries `@spark_dsl_config`, a map keyed by section path
(`lib/spark/dsl/extension.ex:654-725`). Each section entry has the shape established by
`Spark.Dsl.Extension.default_section_config/0` (`lib/spark/dsl/extension.ex:2154-2160`):

```elixir
%{section_anno: nil, entities: [], opts: [], opts_anno: []}
```

plus a reserved `:persist` key holding a flat map written by
`Spark.Dsl.Transformer.persist/3` (`lib/spark/dsl/transformer.ex:88`).

### 2.2 Entities and sections

`%Spark.Dsl.Entity{}` (`lib/spark/dsl/entity.ex:69-93`) carries `name`, `target`, `schema`,
`args`, `entities`, `singleton_entity_keys`, `identifier`, `deprecations`, `describe`, `snippet`,
`examples`, `links`, `hide`, `modules`, `imports`, `no_depend_modules`, `auto_set_fields`,
`transform`, `recursive_as`, `docs`.

`%Spark.Dsl.Section{}` (`lib/spark/dsl/section.ex:33-54`) carries `name`, `schema`, `entities`,
`sections`, `top_level?`, `patchable?`, `deprecations`, `describe`, `snippet`, `examples`,
`imports`, `modules`, `no_depend_modules`, `auto_set_fields`, `singleton_entity_keys`,
`after_define`, `links`, `docs`.

Extension DSL patches are `%Spark.Dsl.Patch.AddEntity{section_path: _, entity: _}`
(`lib/spark/dsl/patch/add_entity.ex:26`).

### 2.3 Source annotations — the thing that makes spans possible

Spark already records `:erl_anno.anno()` at three granularities:

| Granularity | Storage | Accessor |
|---|---|---|
| Section | `section_anno` in the section config | `Spark.Dsl.Extension.get_section_anno/2` (`lib/spark/dsl/extension.ex:202`) |
| Section option | `opts_anno` keyword list | `Spark.Dsl.Extension.get_opt_anno/3` (`lib/spark/dsl/extension.ex:231`) |
| Entity, and per-property | `__spark_metadata__` → `%Spark.Dsl.Entity.Meta{anno:, properties_anno:}` | `Spark.Dsl.Entity.anno/1` (`lib/spark/dsl/entity.ex:424`), `Spark.Dsl.Entity.property_anno/2` (`lib/spark/dsl/entity.ex:449`) |

Two constraints follow directly from the implementation and shape the span model in §4.5:

1. **Annotations exist only under `debug_info`.** `Spark.Dsl.Extension.macro_env_anno/2`
   (`lib/spark/dsl/extension.ex:2206-2213`) returns `nil` unless
   `Code.get_compiler_option(:debug_info)` is true. A production build has no spans.
2. **Column and end-location are best-effort.** `:erl_anno.location/1` returns either `line` or
   `{line, column}`, and `set_end_location/2` is only applied when OTP exports it
   (`lib/spark/dsl/extension.ex:2215-2226`). `Spark.Error.DslError` already branches on exactly
   this (`lib/spark/error/dsl_error.ex:66-80`).

Almost every Ash entity target struct already carries the `__spark_metadata__: nil` field required
to hold an annotation — `%Ash.Resource.Attribute{}` (`lib/ash/resource/attribute.ex:27`),
`%Ash.Resource.Actions.Create{}` (`:36`), `%Ash.Resource.Actions.Read{}` (`:29`),
`%Ash.Resource.Actions.Argument{}` (`:16`), `%Ash.Resource.Calculation{}` (`:25`),
`%Ash.Policy.Policy{}` (`lib/ash/policy/policy.ex:26`),
`%Ash.Policy.Check{}` (`lib/ash/policy/check.ex:22`),
`%Ash.Resource.Interface{}` (`lib/ash/resource/interface.ex:26`). This RFC therefore does not need
to widen any Ash struct.

### 2.4 The option type vocabulary already exists

`Spark.Options.type/0` (`lib/spark/options/options.ex:431-480`) is an enumerated algebra:
`:any | :keyword_list | :map | {:map, k, v} | :atom | :string | :boolean | :integer |
:non_neg_integer | :pos_integer | :float | :number | :timeout | :pid | :reference | :mfa |
:mod_arg | :fun | {:fun, arity} | {:in, values} | {:and, [..]} | {:or, [..]} | {:list, t} |
{:tuple, [t]} | {:one_of, ..} | {:tagged_tuple, tag, t} | {:spark_behaviour, m} |
{:spark_function_behaviour, ..} | {:behaviour, m} | {:protocol, m} | {:impl, m} | {:spark, m} |
{:mfa_or_fun, arity} | {:spark_type, m, f} | {:struct, m} | {:wrap_list, t} | :literal |
{:literal, v} | :quoted | {:custom, m, f, args}`.

`Spark.InfoGenerator.spec_for_type/2` (`lib/spark/info_generator.ex:281+`) already maps a subset of
this to typespec AST. The manifest's type vocabulary (§5) is a JSON rendering of the same algebra
with the closure-bearing cases explicitly quarantined.

### 2.5 Accepted inputs are already cached

`Ash.Resource.Transformers.CacheActionInputs` (`lib/ash/resource/transformers/cache_action_inputs.ex`)
persists, per action:

- `{:action_inputs, action_name}` → a `MapSet` containing **both** the atom and the string form of
  every argument name and every accepted attribute (`:24-28`, `:53`).
- `{:attributes_to_require, action_name}` → the attributes the action will require, computed as
  `accept ++ require_attributes -- allow_nil_input -- argument_names`, then filtered to writable,
  non-generated attributes (`:35-47`, `:55-58`).
- `{:action_select, action_name}` and the resource-wide `:attributes_to_require`.

This is the empirical basis for the accepted-vs-normalized split in §5.3: Ash *already* knows that
an action's accepted input key set includes string keys, and separately knows the required subset.
The manifest surfaces that distinction instead of collapsing it.

### 2.6 Generated code-interface function names are derivable

`Ash.CodeInterface` (`lib/ash/code_interface.ex:1080-1180`) derives, from
`%Ash.Resource.Interface{name:, functions:, args:, get_by:, ...}`:

- `{action_fn, bang_fn}` — `{name, :"#{name}!"}`, or for a `?`-suffixed predicate interface,
  `{name_without_?, name}` (`:1080-1088`).
- `{can_fn, can_question_fn}` — `{:"can_#{name}", :"can_#{name}?"}`, with the predicate variant at
  `:1090-1095`.
- `:"#{subject_name}_to_#{name}"` for `:changeset | :query | :input` subjects (`:1179`).
- Arity: `length(common_args) + 2`, since `params` and `opts` both default (`:1112-1116`).

Every one of these is a pure function of the interface entity, so the manifest can enumerate the
generated function surface with no module loading.

### 2.7 Ash already has a manifest

`Ash.Info.Manifest` (`lib/ash/info/manifest.ex`, ash v3.33.5) is a complete, versioned IR of an
app's Ash surface. It is not a sketch: it has a declared `schema_version/0` of `"1.0.0"`, a
reachability-driven generator, lookup maps, and a JSON serializer with a `mix` task in front of it.

| Piece | Location |
|---|---|
| Top-level struct (`resources`, `types`, `entrypoints`, `filter_capabilities`, `sort_capabilities`, `custom`) | `lib/ash/info/manifest.ex:37-45` |
| `schema_version/0` → `"1.0.0"` | `lib/ash/info/manifest.ex:26, 55` |
| IR structs | `lib/ash/info/manifest/{resource,action,field,argument,argument_signature,relationship,type,metadata,entrypoint,pagination,operator,function,custom_expression,filter_capabilities,sort_capabilities,applicable_*}.ex` |
| Generator pipeline (discover → filter → reachability → build) | `lib/ash/info/manifest/generator.ex:70-180` |
| Type resolution, incl. NewType/Enum hoisting and `:type_ref` | `lib/ash/info/manifest/generator/type_resolver.ex` |
| Per-field applicable operator/function resolution | `lib/ash/info/manifest/generator/operator_resolver.ex`, `capabilities_builder.ex` |
| JSON serialization | `lib/ash/info/manifest/json_serializer.ex` |
| CLI | `lib/mix/tasks/ash.manifest.dump.ex` |
| Lookups (`resource_lookup/1`, `action_lookup/1`, `type_lookup/1`, `operator_lookup/1`, …) | `lib/ash/info/manifest.ex:70-250` |

It is deliberately **runtime- and API-surface-oriented**. Its moduledoc says so: *"Generates a
language-agnostic API specification from Ash resources and actions."* Its generator's visibility
options default to public-only, its `Field` unifies attributes, calculations and aggregates into
one struct because a client cares about the field and not the DSL entity that produced it, and its
`Entrypoint` pairs `{resource, action}` because that is what a client calls.

It carries **no source spans, no stable symbol identifiers, no content digests, and no
provenance**. Nothing in it can answer "where is this declared?", "did this specific declaration
change since I last indexed it?", or "which `use` macro injected this policy?". That is the gap
this RFC fills, and §3 is the field-by-field accounting.


---

## 3. Relationship to `Ash.Info.Manifest`

This section is the audit that the rest of the RFC depends on. Everything v0 defines is either
(a) `Ash.Info.Manifest`'s existing IR, reused under its own names, or (b) one of five things that
IR does not carry. If a reviewer disagrees with a single row below, the corresponding part of the
schema is wrong and should change.

### 3.1 What already exists, and what v0 adds to it

| `Ash.Info.Manifest` concept | Where | v0 disposition |
|---|---|---|
| `%Manifest{resources, types, entrypoints, filter_capabilities, sort_capabilities, custom}` | `manifest.ex:37-45` | **Reused.** v0 is per-module, so it carries `symbols` and a module-scoped `types`; `resources`/`entrypoints`/capabilities stay app-scoped in Ash's document. §3.4. |
| `schema_version/0` = `"1.0.0"` | `manifest.ex:26` | **Reused.** Echoed as the document's `ash_schema_version`. v0's own `manifest_version` versions only the span/identity/provenance layer. §3.3. |
| `%Resource{name, module, embedded?, primary_key, description, fields, relationships, identities, multitenancy}` | `resource.ex:17-37` | **Reused** as the body of the `resource` symbol. v0 adds `domain`, `data_layer`, `authorizers` — DSL facts a runtime API description has no reason to carry. |
| `%Field{name, kind, type, allow_nil?, writable?, has_default?, filterable?, sortable?, primary_key?, sensitive?, select_by_default?, arguments, aggregate_kind, filter_*}` | `field.ex:13-35` | **Reused,** including every flag name. v0 splits it back into `attribute` / `calculation` / `aggregate` symbols because those are distinct DSL entities with distinct spans, and carries `field_kind` as the join key. Net-new: `generated`, and a literal `default` (Ash records only `has_default?`). |
| `%Argument{name, type, allow_nil?, has_default?, required?, description, sensitive?}` | `argument.ex:24-33` | **Reused,** including the `required?` / `allow_nil?` orthogonality its moduledoc spells out. v0 revision 1 had collapsed the two; §11 C6. |
| `%Action{name, type, description, primary?, get?, inputs, metadata, returns, pagination}` | `action.ex:20-30` | **Reused.** `inputs` is Ash's flattened arguments-plus-accepted-attributes list; v0 keeps arguments as their own span-bearing symbols and records the flattening in `accepted_input`/`normalized_input` instead. §3.5 gives the join. |
| `%Relationship{name, type, cardinality, destination, allow_nil?, filterable?, sortable?}` | `relationship.ex:20-30` | **Reused.** Spelled `relationship_type` only because `type` is taken by the typed slot; `filterable`/`sortable` adopted verbatim. |
| `%Type{kind, name, module, constraints, allow_nil?, values, members, resource_module, fields, instance_of, item_type, element_types, resource}` | `type.ex:25-91` | **Reused as the whole type algebra.** v0 revision 1 invented a parallel one; it is withdrawn. §3.2. |
| `%Pagination{offset?, keyset?, required?, countable?, default_limit, max_page_size}` | `pagination.ex:16-27` | **Reused** field for field. |
| `%Metadata{name, type, allow_nil?, description}` | `metadata.ex:9-17` | **Reused** as the action symbol's `metadata`. |
| `%Entrypoint{resource, action, config}` | `entrypoint.ex:17-21` | **Not duplicated.** Ash's entrypoint list is app-scoped; v0 defines the join key instead. §3.5. |
| `%FilterCapabilities{}` / `%SortCapabilities{}` / `%Operator{}` / `%Function{}` / `%CustomExpression{}` / `%ArgumentSignature{}` | `filter_capabilities.ex`, `operator.ex`, `function.ex`, `custom_expression.ex`, `argument_signature.ex` | **Not duplicated.** App-scoped filter vocabulary. A combined dump carries Ash's block unchanged. §11 C8. |
| `%ApplicableOperator/Function/CustomExpression{name, rhs}` | `applicable_operator.ex:38-46` | **Reused verbatim** as optional pass-through on field-shaped symbols, so a v0 consumer does not have to re-resolve what `operator_resolver.ex` already resolved. |
| Lookup maps (`resource_lookup/1`, `action_lookup/1`, `type_lookup/1`, …) | `manifest.ex:70-250` | **Reused as the access pattern.** v0's `types` table is keyed by module exactly as `type_lookup/1` expects. |
| `JsonSerializer.to_map/1` — module atoms → dotted strings, nils omitted | `json_serializer.ex:36-50, 340-350` | **Reused.** v0's canonical-JSON rules (§7.2) are a superset: they add key ordering and number rules because hashes depend on them. |
| `Generator` visibility options (`include_private_*?`) | `generator.ex:47-62` | **Reused.** A v0 emitter takes the same options and means the same thing by them. |

And the other direction — the five things `Ash.Info.Manifest` does not have, which are the entire
substance of this RFC:

| v0 addition | Section | Why Ash's IR cannot carry it today |
|---|---|---|
| `span` and `property_spans` on every symbol | §4.5 | Ash's generator reads `Ash.Resource.Info`, which has already discarded the `__spark_metadata__` annotations Spark recorded (§2.3). Nothing in the IR has a file or a line. |
| Structural symbol ids (`ash:v0:Mod#path/name`) | §4.3 | Ash's IR is addressed by `{module, name}` tuples in Elixir. There is no string identifier a JSON consumer, an editor, or an agent transcript can hold. |
| Three digests per symbol (`identity`, `shape`, `content`) | §4.4 | The IR has no notion of "has this changed?"; a consumer must diff whole documents. |
| `provenance` chains | §4.6 | By the time `Ash.Resource.Info` answers, a transformer-added attribute and a hand-written one are indistinguishable. |
| `accepted` vs `normalized` on every typed slot | §5 | Ash's `Type` is one type per slot. The cast-time surface (`cast_input/2`, string keys, enum aliases) is genuinely wider, and `CacheActionInputs` already stores the evidence (§2.5). |

### 3.2 The type algebra is Ash's

v0 revision 1 defined seventeen type kinds of its own (`primitive`, `list`, `keyword_list`,
`nullable`, `newtype`, `ref`, `tagged_tuple`, …). `Ash.Info.Manifest.Type` already defines thirty
(`type.ex:25-55`), resolved by a 419-line resolver that handles NewTypes, enums, unions, embedded
resources, structs with `instance_of`, arrays, tuples and keyword containers
(`generator/type_resolver.ex`). Keeping both would have meant two vocabularies for the same thing
in the same ecosystem, and a translation layer in every consumer.

**v0 now uses Ash's `kind` enum and Ash's property names**, and adds exactly six kinds that a
runtime API description has no need for but a DSL-option and generated-boundary description does:

| Net-new kind | Needed for |
|---|---|
| `literal` | a section option's literal value; a tagged tuple's tag |
| `literal_union` | `{:in, values}` / `{:one_of, values}` in a `Spark.Options` schema, where there is no Ash type module to hoist |
| `behaviour` | `{:behaviour, m}`, `{:spark, m}`, `{:protocol, m}`, `{:impl, m}` option types |
| `result` | a code-interface function's `{:ok, _} \| {:error, _}` return |
| `page` | a read action's paginated return |
| `dynamic` | the mandatory sink (§8). Ash's `:unknown` is close, but it carries no machine-readable `reason` and is not load-bearing the way `dynamic` is here. |

Six v0 kinds were withdrawn because Ash already expresses them:

| Withdrawn | Now expressed as |
|---|---|
| `primitive` + `name` | one kind per primitive — `string`, `uuid`, `integer`, … — as in `type_resolver.ex:15-39` |
| `list` | `array` with `item_type` |
| `keyword_list` | `keyword` with `fields` |
| `nullable` wrapper | `allow_nil: true` on the type itself |
| `newtype` | `type_ref` plus an entry in the `types` table (exactly Ash's hoisting) |
| `ref` | `type_ref`, with a net-new `symbol` property alongside Ash's `module` |
| `tagged_tuple` | `tuple` whose first `element_types` entry is a `literal` |

Two properties are proposed as additive fields on Ash's `Type`, and are the only places v0 asks
Ash's own IR to grow: **`open`** on `map`/`keyword`, and **`required`** on a field descriptor.
Both exist for the accepted contract (§5.3): an open map with optional keys is not expressible with
`fields` + `allow_nil?` alone, and modelling an optional key as a required key of type `T | nil` is
the exact mistake §5.3 forbids. A third, smaller ask: `Type.constraints` exists in the struct but
`JsonSerializer.serialize_type/1` drops it (`json_serializer.ex:238-256`); v0 requires it in JSON,
because `max_length: 160` is the difference between a useful completion and a guess.

### 3.3 Two version numbers, and what each governs

A combined document carries both:

```json
{ "manifest_version": "0", "ash_schema_version": "1.0.0", ... }
```

- `ash_schema_version` is `Ash.Info.Manifest.schema_version/0`, echoed verbatim. It governs the
  IR shapes v0 reuses. v0 does not fork it and must not diverge from it silently: if Ash bumps to
  `"1.1.0"`, a v0 emitter echoes `"1.1.0"`.
- `manifest_version` governs only the layer this RFC adds — ids, spans, hashes, provenance, the
  accepted/normalized split, and the six net-new type kinds.

Consumers branch on the one they care about. A consumer that only reads Ash's shapes can ignore
`manifest_version` entirely. The compatibility rules in §6.2 apply to `manifest_version`; the
equivalent rules for `ash_schema_version` are Ash's to make.

The natural upstream landing is that the span/identity fields become **additive** members of Ash's
own IR — a `meta` field on `%Field{}`, `%Action{}`, `%Argument{}`, `%Relationship{}` and
`%Resource{}` carrying `{id, span, property_spans, provenance, hashes}` — at which point
`ash_schema_version` goes to `"1.1.0"` and `manifest_version` describes a *profile* of Ash's
manifest rather than a separate document. That is the outcome this RFC is aiming at; §9.1 asks
whether to go straight there.

### 3.4 Scope: per-module vs per-app

`Ash.Info.Manifest` is per-app. `Ash.Info.Manifest.generate(otp_app: :my_app)` walks every domain,
runs reachability over the whole type graph, and emits one document.

v0 is **per-module**, and that is not a stylistic choice — it is forced by invalidation (§7.3).
A language server re-indexing after a keystroke in `team.ex` must not recompute the whole app's
manifest, and a cache keyed on the whole app is invalidated by every edit anywhere. Per-module
documents with `hashes.inputs` are the unit that makes incremental re-indexing possible.

The two scopes compose rather than compete:

- App-scoped, unchanged, emitted by Ash: `resources`, `entrypoints`, `filter_capabilities`,
  `sort_capabilities`, and the app-wide `types` table.
- Module-scoped, emitted by v0: `symbols`, `relations`, `files`, `hashes`, `diagnostics`, and a
  module-scoped `types` table holding the named types *this module* references — a subset of
  Ash's, so `Ash.Info.Manifest.type_lookup/1` semantics still hold after a merge.

A consumer that wants one document merges them. Merging is well-defined because the join keys are.

### 3.5 Join keys

Nothing about joining an Ash manifest to a v0 manifest is heuristic:

| From | To | Key |
|---|---|---|
| `%Resource{module: M}` | v0 `resource` symbol | `"ash:v0:" <> M <> "#resource"` |
| `%Entrypoint{resource: M, action: %{name: A}}` | v0 `action` symbol | `"ash:v0:" <> M <> "#actions/" <> A` |
| `resource.fields[F]` | v0 `attribute` / `calculation` / `aggregate` symbol | `"ash:v0:" <> M <> "#" <> section <> "/" <> F`, where `section` is fixed by `field.kind` |
| `resource.relationships[R]` | v0 `relationship` symbol | `"ash:v0:" <> M <> "#relationships/" <> R` |
| `action.inputs[I]` | v0 `argument` symbol, **or** an accepted attribute | `"…#actions/" <> A <> "/arguments/" <> I` if present, else `"…#attributes/" <> I` |
| `manifest.types[T]` | v0 `types` entry | the `module` property; identical to `type_lookup/1`'s key |

The one asymmetry is `action.inputs`: Ash flattens arguments and accepted attributes into a single
list, and an accepted attribute has no argument symbol to point at. The rule above resolves it, and
it is the only lookup in the table that needs a fallback.

The reciprocal, cheaper direction — Ash emitting the v0 id — is one line in
`JsonSerializer.serialize_entrypoint/1` and is worth proposing on its own merits: an entrypoint
that carries `"symbol_id"` is joinable by any consumer without knowing the id grammar at all.

### 3.6 Tooling: extend the dump, do not add a second one

`mix ash.manifest.dump` already exists (`lib/mix/tasks/ash.manifest.dump.ex`) with
`--output`/`-o` and a `--format` switch that currently accepts only `"json"`. The proposal is a
flag, not a task:

```
mix ash.manifest.dump                 # unchanged; byte-identical output
mix ash.manifest.dump --semantic      # adds spans, ids, hashes, provenance
mix ash.manifest.dump --semantic --per-module -o _build/dev/spark_manifests/
```

`--semantic` is inert unless the app was compiled with `debug_info` (§2.3); without it the emitter
still runs and every `span` is `null`, which is a legal document (§4.5). Whether that should warn
is §9.7.

For Spark DSLs that are not Ash — `AshBpmn`, `AshDecisions`, a third-party extension, or Spark's
own `Spark.Dsl.Fragment` — there is no `Ash.Info.Manifest` to extend, and those DSLs are exactly
the ones with no editor support at all today. `mix spark.semantic` covers them, emitting the same
document with `ash_schema_version: null` and only the generic symbol kinds (`section`, and
whatever the extension's entities project to). This is the split §9.2 asks about: the generic
Spark layer should be enough for a third-party extension to appear in completion without anyone
writing manifest-specific code, and the Ash layer should add the resource/action/policy semantics
on top.


---

## 4. The manifest

### 4.1 Shape

One manifest per DSL module. Top level:

```
manifest_version    "0"                  -- versions the span/identity/provenance layer (§3.3)
ash_schema_version  "1.0.0" | null       -- Ash.Info.Manifest.schema_version/0, echoed (§3.3)
emitter             { name, version }
toolchain           { elixir, otp, spark, ash?, extensions_digest }
module              "AshEnterprise.Accounts.Team"
module_kind         resource | domain | extension | dsl_module
extensions          [ module names, in application order ]
types               [ NamedType ]        -- module-scoped subset of Ash's types table (§3.4)
files               [ { path, digest, role } ]
hashes              { inputs, manifest }
symbols             [ Symbol ]
relations           [ Relation ]
diagnostics         [ Diagnostic ]       -- optional
```

Three further top-level properties are optional and carry no semantics a consumer may rely on:
`generated_at`, `note`, and `abridged` — the last marking a document that deliberately omits
symbols, as the fixture does.

`types` mirrors `%Ash.Info.Manifest{}.types`: named type modules — `Ash.Type.Enum`
implementations, `Ash.Type.NewType` subtypes, embedded resources — are hoisted out of the typed
slots that reference them and carried once, keyed by module, exactly as
`Ash.Info.Manifest.type_lookup/1` expects. Typed slots refer to them with `kind: "type_ref"`.
This is Ash's existing answer to circular references (`type.ex:9-18`) and v0 adopts it unchanged.

`files[].role` is one of `declaration` (the module's own source), `fragment`
(a `Spark.Dsl.Fragment` folded in by `Spark.Dsl.handle_fragments/2`, `lib/spark/dsl.ex:768`), or
`injector` (a module whose `__using__` macro contributed DSL — e.g.
`lib/ash_enterprise/platform/resource.ex` in this repo).

### 4.2 Symbols

A symbol is any addressable declarative thing. v0 defines ten kinds:

`resource`, `attribute`, `action`, `argument`, `relationship`, `calculation`, `aggregate`,
`policy`, `code_interface_function`, `section`.

`aggregate` was added in revision 2 for a specific reason: `Ash.Info.Manifest.Field` already
models aggregates (`field.kind` is `:attribute | :calculation | :aggregate`, `field.ex:11`), so
omitting them would have meant a v0 consumer seeing *fewer* fields than the Ash manifest it is
layered on — the one failure mode a layering design cannot afford. Identities are carried on the
`resource` symbol rather than as their own kind, again following `%Resource{identities:}`.

Ash's `Field` unifies attributes, calculations and aggregates into one struct because a client
calling an action cares about the field, not the entity that produced it. v0 keeps them as three
symbol kinds because they are three different DSL entities, declared in three different sections,
with three different spans and three different provenance chains — and a tool that wants to
navigate to `calculations do ... end` needs that distinction. Each carries `field_kind` as the
explicit join back to `Field.kind` (§3.5).

The list is **open**. The schema carries a fallback branch (`symbolUnknownKind`) that accepts any
other `kind` carrying the common base fields with an unconstrained body, so an emitter can add
`identity`, `validation` or `change` as a symbol kind without bumping `manifest_version`. Per §6.2
consumers must skip kinds they do not recognise.

Every symbol carries: `id`, `kind`, `name`, `dsl_path`, `span`, `property_spans`, `provenance`,
`hashes`, and kind-specific fields. `section` exists so that a consumer can attribute
section-level options (`postgres do table "teams" end`) without inventing a synthetic entity.

### 4.3 Symbol IDs

```
ash:v0:<module>#<dsl_path>/<name>[:<discriminator>]
```

for example

```
ash:v0:AshEnterprise.Accounts.Team#attributes/team_type
ash:v0:AshEnterprise.Accounts.Team#actions/create_default_for_business_unit
ash:v0:AshEnterprise.Accounts.Team#actions/create_default_for_business_unit/arguments/name
ash:v0:AshEnterprise.Accounts.Team#policies/0            <- ordinal discriminator
ash:v0:AshEnterprise.Accounts#code_interface/create_team!/3
```

Design notes:

- **Structural, not content-hashed.** IDs are human-readable and diffable. Content hashing an ID
  would make every id churn on every edit, which is exactly wrong for an identifier that appears in
  editor state, agent transcripts, and cross-manifest relations.
- **Ordinals where there is no name.** Policies have no `name` field
  (`%Ash.Policy.Policy{}` is `condition/policies/bypass?/description/access_type/error_message`).
  Spark's own `identifier` mechanism (`Spark.Dsl.Entity.identifier`, `lib/spark/dsl/entity.ex:83`)
  covers named entities; unnamed ones fall back to **declaration ordinal within the section**, and
  the schema requires `id_stability: "ordinal"` on those symbols so consumers know the id is
  position-dependent. Policy order is semantically significant in Ash anyway (the grant union in
  `lib/ash_enterprise/security/policies.ex` depends on it), so an ordinal is not arbitrary.
- **Domains own code-interface ids.** The generated function lives on the domain module, so its id
  is rooted at the domain, with a `target_action` relation pointing back at the resource's action.

The content-addressed part of identity lives in `hashes`, not the id — see next.

### 4.4 Hashes, and the rename question

Each symbol carries three hashes. All are `sha256` over the **canonical JSON** form (§7.2) of a
defined subset, rendered as `"sha256:" <> Base.encode16(digest, case: :lower)` truncated to 32 hex
characters (128 bits — collision-safe at the scale of a single project, short enough to read in a
diff).

| Hash | Over | Answers |
|---|---|---|
| `identity` | `{module, dsl_path, name_or_ordinal, kind}` | "is this the same symbol?" |
| `shape` | the symbol's semantic payload **with `name` and `id` removed**, spans removed, provenance removed | "is this the same *thing*, possibly renamed?" |
| `content` | the whole symbol **minus `hashes` and minus `span`/`property_spans`** | "did anything semantic change?" |

Spans are excluded from `content` deliberately: moving a declaration down a file must not
invalidate a consumer's semantic cache. Consumers that need to re-anchor spans compare `span`
directly, which is cheap.

**Rename is out of scope, and here is the honest version of why.** A content-hash scheme that
"survives rename" requires either (a) the name to be excluded from identity, which makes two
same-shaped attributes indistinguishable, or (b) durable side-channel state (a `.spark/renames`
journal, or `prior_names` written by a refactoring tool). Option (b) is real work with real failure
modes and does not belong in v0.

What v0 does instead: a rename is emitted as one symbol removed and one added. Because `shape` is
name-free, a consumer diffing two manifests can compute the obvious heuristic — *removed symbol R
and added symbol A in the same `dsl_path` with `R.hashes.shape == A.hashes.shape` is very likely a
rename* — and act on it (preserve editor state, offer a "rename references too?" code action)
without the manifest asserting anything it cannot prove. The schema reserves an optional
`previous_ids: [string]` array on every symbol for a future refactoring tool to populate;
**provenance: proposed**, absent in v0 emitters.

The manifest-level `hashes.inputs` is the invalidation key (§7.3); `hashes.manifest` is the digest
of the emitted document minus the `hashes` object itself, for integrity checks.

### 4.5 Source spans

```json
{
  "file": "lib/ash_enterprise/accounts/team.ex",
  "start": { "line": 59, "column": 5 },
  "end":   { "line": 65, "column": 8 },
  "fidelity": "exact"
}
```

`fidelity` is one of:

- `exact` — `:erl_anno.location/1` returned `{line, column}` and an end location was set.
- `start_only` — start `{line, column}` known, no end location (OTP without
  `:erl_anno.set_end_location/2`, or a do-block whose AST meta lacked `:end_of_expression`;
  see `lib/spark/dsl/extension.ex:2216-2235`).
- `line_only` — `:erl_anno.location/1` returned a bare integer.
- `absent` — no annotation. **This is the normal case when `debug_info` is off**, and it is
  therefore not an error; the `span` key is simply `null`.

File paths are **repo-relative POSIX paths**, normalized from the charlist that
`:erl_anno.file/1` returns. Spark's own error formatting already does this relativization
(`Path.relative_to_cwd/1`, `lib/spark/error/dsl_error.ex:73`). Absolute paths must not be emitted:
they leak build-machine layout and break manifest portability and caching across machines.

`property_spans` is a map from option name to span, populated from
`Spark.Dsl.Entity.property_anno/2` for entities and `Spark.Dsl.Extension.get_opt_anno/3` for
section options. This is what lets a diagnostic underline `allow_nil? false` rather than the whole
`attribute` block.

### 4.6 Provenance chain

`provenance` is an **ordered list, oldest step first**. Each step:

```json
{ "stage": "macro_injected", "by": "AshEnterprise.Platform.Resource", "span": {...}, "note": "use/2" }
```

`stage` is one of:

| Stage | Real mechanism | Span available? |
|---|---|---|
| `declared` | written in a section in the module's own file | yes (entity anno) |
| `fragment` | folded in from a `Spark.Dsl.Fragment` by `Spark.Dsl.handle_fragments/2` (`lib/spark/dsl.ex:768`) | yes — anno carries the fragment's file |
| `macro_injected` | emitted by a user `__using__` macro, e.g. `AshEnterprise.Platform.Resource.__using__/1` at `lib/ash_enterprise/platform/resource.ex:116-228` | yes — the anno points at the `use` site, because `macro_env_anno/2` uses `env.file`/`env.line` |
| `extension_patch` | `%Spark.Dsl.Patch.AddEntity{}` contributed by an extension | no anno today |
| `transformer_added` | `Spark.Dsl.Transformer.add_entity/3` | **no** — see below |
| `option_default` | value filled by `Spark.Options.validate/2` from the schema's `:default` | no; `by` is the extension that owns the schema |
| `auto_set` | `auto_set_fields` on the entity/section | no; `by` is the extension |
| `generated_code` | a function emitted by `Ash.CodeInterface` | derived; span points at the `define` entity |

**The transformer gap, stated plainly.** `Spark.Dsl.Transformer.add_entity/4`
(`lib/spark/dsl/transformer.ex:272-282`) accepts only `type: :prepend | :append`. There is no
record of *which* transformer added an entity. In this repo,
`AshEnterprise.Platform.Transformers.AddSystemAttributes` adds twelve attributes and two
calculations (`lib/ash_enterprise/platform/transformers/add_system_attributes.ex`), and after
compilation they are indistinguishable from hand-written ones.

Proposed minimal, additive hook — **provenance: proposed**:

```elixir
# in Spark.Dsl.Transformer
def add_entity(dsl_state, path, entity, opts \\ [])
#   opts :: [type: :prepend | :append, attribution: module() | {module(), term()}]
```

When `:attribution` is absent, behaviour is byte-identical to today. When present, Spark records it
in the entity's `__spark_metadata__` (which already exists and is already `nil`-tolerant). A
manifest emitter without this hook emits `{"stage": "transformer_added", "by": null}`, which the
schema permits. A fallback heuristic — "entity has no anno and the section is not in the module's
own file list, therefore `transformer_added` with `by: null`" — is sound for detecting *that* a
transformer added it, and is what v0 ships with.

The second proposed hook, also additive: `Spark.Dsl.Extension.set_option/4` similarly has no
attribution, which is why `AddSystemAttributes` setting `[:multitenancy]` strategy/attribute/global?
(`add_system_attributes.ex:247-252`) shows up as a plain option with no origin.

### 4.7 Relations

Cross-symbol edges, kept out of the symbols so the graph can be walked without parsing every
symbol body:

```json
{ "from": "<symbol id>", "to": "<symbol id or module ref>", "kind": "generated_from" }
```

v0 kinds: `contains`, `generated_from`, `transformed_from`, `added_by_extension`,
`accepts_input`, `returns`, `references_type`, `references_named_type`, `references_resource`,
`guarded_by`, `implements_action`, `joins_through`.

`references_named_type` is the edge from a symbol to an entry in the `types` table (§4.1) or, when
the named type is not in this module's table, to a module name resolved against the app-scoped Ash
manifest.

`to` may be a symbol id in *another* module's manifest (e.g. a relationship's `destination`). The
consumer resolves it lazily; the manifest does not inline foreign symbols. This keeps manifests
independently cacheable per module, which is the whole point.

---

## 5. Type vocabulary: accepted vs normalized

### 5.1 Why two types

The architecture doc puts it as: *"Ash's DSL may know that an action requires
`%{email: String.t(), role: :admin | :member}`, yet the generated boundary may accept a broad map
because casting, defaults, aliases, omitted optional values, unknown-input handling, and runtime
errors are part of the action contract."*

This is not hand-wringing; it is visible in the code. `Ash.Type` declares `cast_input/2`
separately from `cast_stored/2` and `dump_to_native/2` (`lib/ash/type/type.ex:385, 418, 429`), and
`CacheActionInputs` stores both the atom and the string form of every input name
(`cache_action_inputs.ex:28`). The accepted surface is genuinely wider than the normalized one, and
a manifest that reports only one of them is lying to at least one consumer.

So **every typed slot in the manifest carries two type terms**: `accepted` and `normalized`. They
are frequently different and that is the point.

### 5.2 The JSON type algebra — `Ash.Info.Manifest.Type`, plus six

The vocabulary is `Ash.Info.Manifest.Type`'s (`ash lib/ash/info/manifest/type.ex:25-91`), not a
new one. v0 revision 1 invented a parallel algebra; §3.2 records why that was withdrawn and what
each withdrawn kind is now spelled as.

**Ash's thirty kinds, reused verbatim:**

```
string  integer  boolean  float  decimal  uuid  date  datetime  utc_datetime
utc_datetime_usec  naive_datetime  time  time_usec  duration  binary  atom
ci_string  term  enum  union  resource  embedded_resource  map  struct  array
tuple  keyword  type_ref  any  unknown
```

and Ash's property names with them — `name`, `module`, `constraints`, `allow_nil`, `values`
(enum), `members` (union), `fields` (map/struct/keyword), `element_types` (tuple), `item_type`
(array), `instance_of` (struct), `resource_module` (resource/embedded_resource).

**The six v0 adds**, for DSL options and generated boundaries, which a runtime API description has
no reason to describe:

```
{ "kind": "literal",       "name": "Literal",      "value": <json> }
{ "kind": "literal_union", "name": "LiteralUnion", "values": [<json>, ...] }   // finite, closed
{ "kind": "behaviour",     "name": "Change",       "module": "Ash.Resource.Change" }
{ "kind": "result",        "name": "Result",       "ok": Type, "error": Type }
{ "kind": "page",          "name": "Page",         "item_type": Type,
                                                   "strategies": ["offset"|"keyset", ...] }
{ "kind": "dynamic",       "name": "Dynamic",      "reason": "<machine-readable>",
                                                   "repr": "<bounded inspect/1>"? }
```

**Two properties proposed as additive on Ash's own `Type`** (§3.2), used only by the accepted
contract: `open` on `map`/`keyword`, and `required` on a field descriptor. Until they land upstream
they are v0-local; they are marked **provenance: proposed** in the schema.

`name` is required on every term, because Ash's serializer always emits it
(`json_serializer.ex:240-244`) and a document that sometimes omits it is not interchangeable with
Ash's.

Mapping from `Spark.Options.type/0` (§2.4) is total, because `dynamic` is the sink:

| Spark option type | Manifest term |
|---|---|
| `:atom`, `:string`, `:integer`, `:boolean`, `:float`, `:pos_integer`, … | the matching Ash primitive kind — `atom`, `string`, `integer`, … — with `module` set as `type_resolver.ex:15-39` sets it |
| `{:in, vs}` / `{:one_of, vs}` with a finite enumerable | `literal_union` |
| `{:in, %Range{}}` | `integer` with `constraints.range` |
| `{:list, t}` / `{:wrap_list, t}` | `array` with `item_type` |
| `{:tuple, ts}` | `tuple` with `element_types` |
| `{:tagged_tuple, tag, t}` | `tuple` whose first `element_types` entry is a `literal` |
| `{:or, ts}` | `union` with `members` |
| `{:and, ts}` | `union` with an `"intersection": true` flag — **provenance: proposed**, v0 emits `dynamic` |
| `{:map, k, v}` | `map` with `open: true` and `key_type`/`value_type` |
| `:keyword_list` / `:non_empty_keyword_list` with `keys:` | `keyword` with `fields` |
| `{:struct, m}` | `struct` with `instance_of: m` |
| `{:behaviour, m}` / `{:protocol, m}` / `{:impl, m}` / `{:spark, m}` / `{:spark_behaviour, …}` | `behaviour` |
| `:mfa`, `:mod_arg`, `{:spark_function_behaviour, …}`, `{:mfa_or_fun, n}` | `union` of `tuple` and `dynamic(reason: "function_reference")` |
| `:fun`, `{:fun, _}`, `{:custom, m, f, a}`, `:quoted`, `:pid`, `:reference` | `dynamic` with the matching reason |
| `:any`, `:literal` | `dynamic(reason: "unconstrained")` |

Ash types are not mapped by this RFC at all: they are resolved by
`Ash.Info.Manifest.Generator.TypeResolver.resolve/2`, and a v0 emitter calls it rather than
reimplementing it. Named types follow Ash's hoisting rule — this repo's
`AshEnterprise.Accounts.Types.TeamType` (`lib/ash_enterprise/accounts/types/team_type.ex`, an
`Ash.Type.Enum`) appears once in the `types` table as `{"kind": "enum", "values": [...]}` and is
referenced from every typed slot as `{"kind": "type_ref", "module": "…TeamType"}`, which is
exactly what `resolve/2` and `resolve_definition/1` already do
(`generator/type_resolver.ex:83-92, 105-125`).

Two v0-local extensions to `type_ref` are worth naming, because they are where the module-scoped
and app-scoped documents meet:

- `symbol` alongside `module`, so a reference can point at a v0 symbol id rather than a type
  module. Used for a code-interface function whose params are "whatever this action accepts".
  When both are present, `module` is authoritative.
- A `type_ref` whose `module` is not in this document's `types` table is resolved against the
  app-scoped Ash manifest. This is the same lazy-resolution rule §4.7 applies to relations, and it
  is what keeps per-module documents independently cacheable.

### 5.3 The two contracts, concretely

For an action symbol:

- **`accepted_input`** — a `map` with `open: true`, whose value types are the pre-cast surface for
  each input (`cast_input/2`'s domain), and whose `required: true` entries are
  `{:attributes_to_require, name}` minus anything with a default. Optional inputs are
  **`required: false` field descriptors**, never "required key typed `T | nil`" — the distinction
  matters to every structural type checker, and it is the reason `required` has to exist on the
  descriptor at all (§3.2). Because `{:action_inputs, name}` holds both the atom and the string
  form of every key, each descriptor carries `name_repr: "atom_or_string"` rather than the key
  being listed twice; that is §7.2 rule 5 applied to the one place the distinction is load-bearing.
- **`normalized_input`** — a `map` with `open: false`, `name_repr: "atom"` throughout, post-cast
  value types, defaults applied. This is what a change/validation/preparation actually receives.
- **`returns`** — a `result` whose `ok` is the resource struct (create/update), an `array` of it, a
  `page`, `:ok`-only for destroy, or the declared generic-action return type. Bang variants carry
  `raising: true` and a bare `ok` type with the error arm moved into `raises`.

Ash's `%Argument{}` already draws this exact line and says so in its moduledoc: `required?` is
"whether a caller must supply this argument at all", while `allow_nil?` and `has_default?`
"describe the shape of the value once supplied". v0 revision 1 had flattened the two into a single
`allow_nil` plus a denormalized `required_inputs` list; revision 2 carries Ash's `required` on the
argument symbol and keeps `required_inputs` only as the convenience view it always was — the same
denormalization Ash itself does with `predicate_operators`
(`filter_capabilities.ex:12-16`).

For an attribute symbol, `accepted` is `cast_input/2`'s domain (e.g. `:uuid` accepts a canonical
binary string *or* a raw 16-byte binary) and `normalized` is the stored representation. Ash's
`%Field{}` carries one type for both, which is correct for its purpose and insufficient for
completion at a cast boundary; the `accepted` term is the net-new half.

**Soundness rule, normative:** an emitter must never narrow. If it cannot prove the narrow type it
must emit the wider one, and `dynamic` is always a legal answer. A false `literal_union` is worse
than an honest `dynamic`, because it turns a working program into a reported error.

---

## 6. Versioning and compatibility

### 6.1 Version field

`manifest_version` is a string holding a **major version only**: `"0"`, then `"1"`. Minor changes
do not bump it; they are discovered by presence.

### 6.2 Compatibility rules (normative)

**Additive within a major version** — an emitter MAY, without bumping `manifest_version`:

- add a new optional property to any object;
- add a new value to an open-ended enum (`provenance[].stage`, `relations[].kind`,
  `type.kind`, `symbol.kind`, `diagnostics[].severity`);
- populate a property that was previously always `null`.

**Consumer obligations** — a conforming consumer MUST:

- ignore unknown object properties;
- treat an unknown `kind`/`stage` as an opaque value and degrade (for a type, treat it as
  `dynamic`; for a symbol, skip it; for a relation, ignore the edge) rather than error;
- tolerate `span: null` and `provenance[].by: null` everywhere;
- not assume `symbols` is ordered, except that symbols sharing a `dsl_path` appear in **declaration
  order**, which is semantically meaningful for policies.

**Breaking — requires `manifest_version: "1"`:**

1. Removing or renaming any property.
2. Changing a property's JSON type, including making an optional property required.
3. Changing the symbol-id grammar (§4.3), including the ordinal fallback.
4. Changing the hash input subsets or the digest algorithm/truncation in §4.4.
5. Changing the canonical-JSON rules in §7.2 (this silently changes every hash).
6. Narrowing the meaning of an existing `type.kind` — e.g. making `map` closed by default.
7. Making `span` file paths absolute, or changing their base.
8. Diverging from `Ash.Info.Manifest`'s shapes for a concept §3.1 lists as reused — renaming
   `filterable`, re-scoping `required`, or forking the `type.kind` enum. A change of that sort is
   breaking even if the JSON still validates, because it breaks the join in §3.5.

`ash_schema_version` is **not** governed by these rules; it is Ash's to version. A v0 consumer
that reads the reused shapes should branch on `ash_schema_version`, and one that reads spans, ids,
hashes or provenance should branch on `manifest_version`. Most consumers read both and should
check both.

Anticipated v0→v1 candidates, listed now so reviewers can object early: modelling Ash expressions
instead of `dynamic`; making transformer `attribution` required once the Spark hook lands; adding
`previous_ids` as a populated field; adding an intersection type kind for `{:and, _}`.

### 6.3 Negotiation

Consumers declare the versions they understand. A cached manifest whose `manifest_version` is
unknown to the consumer is treated as a cache miss, not an error. The same rule applies
independently to `ash_schema_version`: a consumer may understand the span layer and not the IR
version beneath it, or the reverse, and in either case the answer is a cache miss.
Spark ships `Spark.SemanticManifest.supported_versions/0` — **provenance: proposed**.

### 6.4 Relationship to Spark/Ash versions

`toolchain.spark` and `toolchain.ash` are the *package* versions. They are recorded but are
**not** part of the compatibility contract: a consumer must not gate on them. They exist for
diagnostics and for the invalidation key (§7.3).

`ash_schema_version` is a different thing and is not covered by that prohibition — it is the
declared version of `Ash.Info.Manifest`'s serialization format, and a consumer reading the reused
shapes (§3.1) may and should branch on it. The two things a consumer may branch on are therefore
`manifest_version` and `ash_schema_version`; package versions are never one of them.

---

## 7. Serialization, canonical form, and caching

### 7.1 Format decision: JSON, schema'd

**Decision: JSON as the normative interchange format,** described by
`docs/rfc/semantic-manifest-v0.schema.json` (JSON Schema draft 2020-12).

Rationale:

- Three of the four consumers are not Elixir-first. Expert is (ETF would be fine there), but an MCP
  tool serving coding agents, a Clarity importer, and a docs exporter all want JSON. Choosing ETF
  would force a JSON shim in three places and make the schema unenforceable.
- A machine-checkable schema is the actual deliverable. "The contract four consumers code against"
  means nothing without a validator in CI; JSON Schema gives that for free in every language.
- Spark already has precedent for a derived, serialized projection of DSL state:
  `Spark.CheatSheet` and `mix spark.cheat_sheets` (`lib/spark/cheat_sheet.ex`,
  `lib/mix/tasks/spark.cheat_sheets.ex`). This is the same idea with a machine-readable target.
- Ash has already made this call. `Ash.Info.Manifest.JsonSerializer` emits JSON, and
  `mix ash.manifest.dump` is JSON-only by construction (it raises on any other `--format`,
  `ash.manifest.dump.ex:44-47`). Choosing anything else would have put two serializations of the
  same data in the same repository.

The conventions in `Ash.Info.Manifest.JsonSerializer` are adopted rather than re-litigated: module
atoms render as dotted strings without the `Elixir.` prefix (`json_serializer.ex:340-350`), atoms
render as bare strings, and `nil` fields are omitted (`put_if_present/3`). §7.2 adds only what
hashing forces — key ordering, whitespace, and number rules — and one divergence, recorded here so
it is not a surprise: `Type.constraints` is dropped by Ash's serializer today and is **required**
in a v0 document (§3.2).

ETF remains available as a **transport optimization**, not a second contract: an in-VM consumer may
receive `:erlang.term_to_binary/1` of the same structure, and it must decode to a document that
validates against the schema once rendered to JSON. If the two ever disagree, JSON wins.

Files are written to `_build/<env>/spark_manifests/<Module>.json` and are build artifacts, not
source. They are not checked in.

### 7.2 Canonical JSON (normative — hashes depend on it)

1. UTF-8, no BOM.
2. Object keys sorted by Unicode code point.
3. No insignificant whitespace.
4. Numbers: integers only, emitted without exponent or trailing `.0`. Floats appearing in DSL
   values are serialized as a `{"kind":"literal","name":"Literal"}` with a **string** `value` carrying the Elixir
   source representation, because float round-tripping is not portable.
5. Atoms are strings **without** the leading colon. A slot that could hold either an atom or a
   string carries a sibling `*_repr: "atom" | "string"` where the distinction is semantic (it is,
   for action input keys).
6. `null` is emitted explicitly for "known to be absent"; a property is omitted for "not applicable
   to this symbol kind". Consumers must treat both the same.
7. Arrays preserve declaration order.

### 7.3 Invalidation

```
file_digest      = sha256(file bytes)                          -- per entry in files[]
extensions_digest= sha256(canonical([{ext_module, beam_digest(ext_module)} | sorted]))
toolchain_digest = sha256(canonical({elixir, otp, spark, ash, emitter.version}))
hashes.inputs    = sha256(canonical({files: [digests in files[] order],
                                     extensions: extensions_digest,
                                     toolchain:  toolchain_digest}))
hashes.manifest  = sha256(canonical(manifest without the "hashes" object))
```

Consumer rule: recompute `hashes.inputs` — which requires only stat+read of the listed files and
the already-cached extension/toolchain digests, never a compile — and reuse the cached manifest if
it matches. `hashes.manifest` is for integrity only.

Two deliberate properties:

- **`files[]` includes injector files.** Editing `lib/ash_enterprise/platform/resource.ex`
  invalidates the manifest of every resource that `use`s it. Without this the cache is wrong in
  exactly the case that matters most in this codebase.
- **`extensions_digest` uses BEAM digests, not versions.** A locally modified extension in `deps/`
  or in-project changes behaviour without changing a version string.

Per-symbol `hashes.content` supports the finer operation a language server actually wants: given
two manifests for the same module, emit the minimal changed-symbol set and re-index only those.

---

## 8. What must NOT be in the portable manifest

This section is normative and is the one an emitter should be tested against first. A manifest is
a **portable data document**. Everything below either cannot survive serialization, cannot survive
crossing a node boundary, or is a security problem.

**Hard prohibitions.** An emitter MUST NOT serialize:

1. **Anonymous functions and captures.** `&Module.fun/1`, `fn -> ... end`. These appear all over
   real DSLs — `Spark.Dsl.Entity.transform` (`{module, fun, args}` *or* a capture),
   `Ash.Resource.Attribute.default` (`default &DateTime.utc_now/0`), `Ash.Policy.Policy.error_message`
   (typed as `(subject, ctx -> String.t() | Exception.t())`, `lib/ash/policy/policy.ex:39-40`),
   `Spark.Options` `{:custom, m, f, a}` and `:fun` types. Emit
   `{"kind":"dynamic","name":"Dynamic","reason":"anonymous_function",
   "repr":"#Function<1.2345/0 in Foo.bar/1>"}`
   plus the `property_span` so a consumer can *show the source*, which is what it wanted anyway.
   An MFA tuple, being plain data, MAY be emitted as a `tuple` of module/atom/args.
2. **Pids, references, ports.** No exceptions. There is no representation that means anything after
   the emitting process dies.
3. **Runtime-created atoms.** A consumer MUST NOT call `String.to_atom/1` on any manifest string.
   Decoding a manifest from an untrusted or stale source into atoms is an unbounded memory leak
   (the atom table is not garbage-collected) and the schema is explicitly designed so that no
   consumer ever needs to: all identifiers are compared as strings, and any consumer needing an
   atom must use `String.to_existing_atom/1` and handle failure. Emitters MUST NOT create atoms
   while emitting either.
4. **Compiled regexes.** `%Regex{}` is version-fragile across OTP. Emit
   `{"kind":"struct","name":"Regex","module":"Ash.Type.Struct","instance_of":"Regex",
   "constraints":{"source":"...","opts":"iu"}}`.
5. **`Macro.Env` structs and raw quoted AST of user callbacks.** An `Macro.Env` carries the whole
   lexical environment including aliases, imports, and a function stack; it is large, non-portable,
   and leaks paths. Spark stores one at `dsl[:persist][:env]`
   (`lib/spark/dsl/extension.ex:748`) — it must be dropped, not projected. Quoted AST MAY be
   emitted only for *expression* slots, only behind an explicit `include_expressions: true` emitter
   option, and only as a `repr` string, never as a structure a consumer might evaluate.
6. **Opaque struct internals.** `%MapSet{}` must be emitted as a JSON array
   (`{:action_inputs, _}` is a MapSet — `cache_action_inputs.ex:53`), not as
   `{"__struct__": "MapSet", "map": {...}}`. The same applies to any struct whose internal
   representation is private.
7. **Secrets and anything resolved from the environment.** Spark's `{:spark_type, m, f}` and Ash's
   secret-function pattern (`AshEnterprise.Secrets` in this repo) mean an option's *value* may be
   an API key or a signing secret. The manifest records the **shape and the provider module**, never
   a resolved value. Emitters MUST treat any option whose schema marks it `sensitive?`/`private?`,
   and any `Ash.Resource.Attribute` or `Argument` with `sensitive?: true`, as value-redacted:
   the type is emitted, the default and any literal are replaced with
   `{"kind":"dynamic","name":"Dynamic","reason":"redacted_sensitive"}`.
8. **Absolute filesystem paths.** §4.5. They break cache sharing and leak the build machine.
9. **Anything requiring the module to be loaded to interpret.** If a consumer must call
   `Module.function/n` to make sense of a field, the field is wrong. That is the entire premise.

**The escape hatch is mandatory.** Every prohibited value has exactly one legal rendering: a
`dynamic` node with a machine-readable `reason`, an optional human `repr` from `inspect/1` with
`limit`/`printable_limit` bounded, and — where available — the `property_span` pointing at the
source. `dynamic` is not a failure; it is the manifest telling the truth about a dynamic language.
A consumer that sees `dynamic` falls back to whatever it does today.

---

## 9. Open questions for review

The questions below are numbered and are referred to elsewhere in this document as §9.1, §9.2 and
so on. The first three are new in revision 2 and are the ones that decide the shape of the
contribution.

1. **Extend the struct, or layer a document?** §3.3 sketches the endgame: a `meta` field on
   `%Field{}`, `%Action{}`, `%Argument{}`, `%Relationship{}` and `%Resource{}` carrying
   `{id, span, property_spans, provenance, hashes}`, serialized by the existing
   `JsonSerializer`, `ash_schema_version` to `"1.1.0"`, and no second document at all. That is
   cleaner than a parallel file and makes every existing `Ash.Info.Manifest` consumer span-aware
   for free. It is also more invasive: five structs grow a field, and the generator has to thread
   annotations it does not currently read. Which does Ash prefer as the *first* PR?
2. **Where does emission live?** `Spark.SemanticManifest` emitting a generic DSL manifest, with
   `Ash` contributing the resource/action/policy projection; or one Ash-side emitter? The split
   matters for extension authors: the generic layer should be enough for a third-party Spark
   extension — `AshBpmn`, `AshDecisions`, anything — to appear in completion without writing any
   manifest code, and those extensions have no `Ash.Info.Manifest` to extend (§3.6). If the answer
   is "Ash-side only", non-Ash Spark DSLs stay unserved and `mix spark.semantic` should be dropped
   from the proposal.
3. **The three additive asks on Ash's IR** (§3.2), in ascending order of intrusiveness:
   serializing `Type.constraints`, which is already in the struct and merely dropped by
   `serialize_type/1`; `open` on `map`/`keyword`; and `required` on a field descriptor. The first
   looks like a plain bug fix and could ship alone. Are the second and third welcome on `%Type{}`,
   or should they stay in the v0 layer?
4. **Scope.** §3.4 argues per-module documents are forced by incremental invalidation, against
   Ash's per-app generation. Is there an objection to per-module emission — or a preferred merged
   form that still lets a language server re-index one file's worth of change?
5. **Attribution hook (§4.6).** Is `attribution:` on `Transformer.add_entity/4` and
   `Extension.set_option/4` acceptable as an optional keyword, or would Spark prefer to infer it
   from the currently-running transformer in `run_transformers/4`
   (`lib/spark/dsl/extension.ex:747`)? The latter is strictly less invasive at the call site and
   requires no extension author to change anything — it may be the better proposal.
6. **Domain-level manifests.** Code-interface functions live on the domain but describe resource
   actions. v0 roots them at the domain (§4.3) and relates across. Is a merged domain manifest
   preferable for consumers?
7. **`debug_info` dependency.** Spans vanish without it (§2.3). Should `--semantic` warn when the
   app was compiled without it, or silently emit `span: null` throughout?
8. **Expression modelling.** v0 punts to `dynamic` + span. Is there appetite for an
   `Ash.Expr` → manifest projection sooner than Phase 6?

---

## 10. Exit criteria for this RFC (Phase 0)

- [x] Symbol id scheme, span model, provenance model, type vocabulary, versioning, serialization,
      caching, and exclusions defined.
- [x] Field-by-field reconciliation with `Ash.Info.Manifest`, with every consolidation recorded
      (§3, §11).
- [x] Machine-checkable schema: `docs/rfc/semantic-manifest-v0.schema.json`, validated as
      JSON Schema draft 2020-12.
- [x] A hand-authored fixture for a real resource, validating against that schema:
      `docs/rfc/fixtures/ash_enterprise_accounts_team.manifest.json`.
- [ ] Reviewed by the Spark/Ash maintainer; open questions in §9 resolved — §9.1 first, since it
      decides whether the deliverable is a PR against `Ash.Info.Manifest` or a document beside it.
- [ ] A validator in CI and a golden-test harness comparing DSL source → compiled DSL state →
      manifest (Phase 0 exit in the architecture doc), plus a round-trip test asserting that the
      reused shapes in §3.1 stay byte-comparable with `Ash.Info.Manifest.JsonSerializer`'s output
      for the same app.

---

## 11. Changelog — revision 2: rebased on `Ash.Info.Manifest`

Revision 1 was drafted without accounting for `Ash.Info.Manifest` (`ash` v3.33.5,
`schema_version "1.0.0"`). It duplicated several concepts that already had a shape in that IR.
Every such duplication is collapsed below, onto Ash's shape rather than v0's. Changes are
**breaking against revision 1**, which was never published, so `manifest_version` stays `"0"`.

| # | Consolidation | Revision 1 | Revision 2 |
|---|---|---|---|
| **C1** | **Type algebra** | Seventeen invented kinds with invented property names (`of`, `required`/`optional` maps, `nullable`, `primitive` + `name`). | `Ash.Info.Manifest.Type`'s thirty kinds and property names (`item_type`, `element_types`, `members`, `fields`, `values`, `instance_of`, `resource_module`, `allow_nil`), plus six net-new kinds for DSL-option and boundary typing. `primitive`, `list`, `keyword_list`, `nullable`, `newtype`, `ref` and `tagged_tuple` withdrawn. §3.2, §5.2. |
| **C2** | **Named-type hoisting** | Named types inlined at every reference as `newtype` wrapping a `literal_union`. | A module-scoped `types` table keyed by module, referenced by `type_ref` — Ash's existing answer to circular references (`type.ex:9-18`, `type_resolver.ex:83-92`). §4.1. |
| **C3** | **Resource body** | `domain`, `data_layer`, `authorizers`, `primary_key`, `multitenancy`, `struct_type`; no identities; `name: null`. | Adds `embedded` and `identities` from `%Resource{}`, and `name` now carries Ash's `Resource.name`. Multitenancy key names already matched (`strategy`/`global`/`attribute`). |
| **C4** | **Field flags and the aggregate gap** | Attribute and calculation symbols with an ad-hoc flag set; no aggregates. | `%Field{}`'s flag names adopted wholesale, `has_default` and `select_by_default` added, `field_kind` added as the join key to `Field.kind`, and an `aggregate` symbol kind added so v0 never exposes fewer fields than the Ash manifest beneath it. §4.2. |
| **C5** | **Action body** | No `get?`, no `metadata`; `pagination.countable` untyped. | `get` and `metadata` adopted from `%Action{}`; `pagination` matches `%Pagination{}` field for field. `argument_ids` documented as v0's deliberate un-flattening of Ash's `inputs`, with the join rule in §3.5. |
| **C6** | **Argument presence vs nullability** | One `allow_nil` flag, with presence pushed into the action's `required_inputs`. | `required` adopted from `%Argument{}`, whose moduledoc makes the orthogonality explicit; `has_default` added; `required_inputs` demoted to the convenience view it always was. §5.3. |
| **C7** | **Relationship body** | No `filterable`/`sortable`. | Both adopted from `%Relationship{}`. `relationship_type` keeps its name only because `type` is taken by the typed slot, and now says so. |
| **C8** | **Filter vocabulary** | Absent — v0 modelled no filter capabilities at all, and would have grown its own. | Not modelled, deliberately: `%FilterCapabilities{}` and `%SortCapabilities{}` are app-scoped and a combined dump carries Ash's block unchanged. Per-field `%ApplicableOperator/Function/CustomExpression{}` are carried as verbatim pass-through so no consumer re-resolves what `operator_resolver.ex` already resolved. |
| **C9** | **Versioning** | One `manifest_version`. | Two numbers with disjoint remits: `ash_schema_version` echoes Ash's and governs the reused shapes; `manifest_version` governs only the span/identity/provenance layer. §3.3, §6.2 rule 8. |
| **C10** | **Tooling** | A new `mix spark.semantic` as the only entry point. | A `--semantic` flag on the existing `mix ash.manifest.dump`; `mix spark.semantic` retained only for Spark DSLs with no Ash projection, and §9.2 asks whether even that is wanted. §3.6. |
| **C11** | **Serialization conventions** | Specified from scratch. | `JsonSerializer`'s conventions adopted (dotted module strings, bare atoms, nils omitted); §7.2 adds only what hashing forces, and the one divergence — requiring `Type.constraints`, which Ash's serializer drops — is called out rather than assumed. §7.1. |

Three things revision 1 got right and revision 2 keeps unchanged, because `Ash.Info.Manifest`
has no equivalent and nothing about it argues against them: the `fidelity` enum on spans
(`exact` / `start_only` / `line_only` / `absent`, §4.5), the hard prohibitions on what may not be
serialized (§8), and the compatibility rules in §6.2 — extended by one clause, rule 8, which makes
divergence from Ash's reused shapes itself a breaking change.
