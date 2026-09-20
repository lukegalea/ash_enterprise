# Source Map — Spark/Ash/Expert/Clarity/Tidewave Extension Points (FIRST-3)

Full report by explorer agent from .slim/clonedeps clones (spark v2.7.3, ash v3.33.5, expert main, clarity v0.6.0, tidewave main). Key findings + exact locations:

## Spark (v2.7.3)
- DSL state: process dict during expansion ({module, :spark, section_path}); post-compile it is COMPILED INTO FUNCTIONS: spark_dsl_config/0, entities/1, persisted/1 (lib/spark/dsl.ex:626-739). __using__ registers @before_compile Spark.Dsl (dsl.ex:368) + @after_verify __verify_spark_dsl__ (dsl.ex:464).
- Emitter hooks (2 candidates): Spark.Dsl.__before_compile__ → handle_before_compile (dsl.ex:457-460); or __after_verify__ post-verification phase running after_compile? transformers (dsl.ex:467-529; transformer after_compile? callback at dsl/transformer.ex:68) — preferred for a semantic manifest (post-transform, post-verify).
- Source spans EXIST: Spark.Dsl.Entity.Meta{anno, properties_anno} via __spark_metadata__ (entity.ex:230-312); section/opt annos via get_section_anno/get_opt_anno (transformer.ex:321,331). Clarity already consumes these (Clarity.SourceLocation). Manifest schema should embed this format.
- ElixirSense plugin: lib/spark/elixir_sense/plugin.ex (1304 lines), polymorphic host adapters (ElixirSense.Plugin / ElixirSense.Providers.Plugin / ElixirLS variants) gated by Code.ensure_compiled.

## Ash (v3.33.5)
- ⚠ PRE-EXISTING MANIFEST: lib/ash/info/manifest.ex — Ash.Info.Manifest (schema_version "1.0.0"), IR structs in lib/ash/info/manifest/ (resource, action, field, argument, relationship, type, operator, pagination...), generators in manifest/generator/, JSON via manifest/json_serializer.ex, mix task ash.manifest.dump. Runtime-oriented, NO source spans. => Our work = extend this IR with spans/provenance/stable symbol IDs; never reinvent.
- Code interfaces: lib/ash/code_interface.ex (3129 lines). define_interface/3 macro (line 429); get_by casting at apply_get_by_filter/3 (1521), cast_get_by_filter_params/3 (1544), cast_get_by_field/4 (1573); atomic path line 2336. NO @spec emitted for generated interface functions.
- get_by fix (#1971) already has runtime cast machinery here — fix likely wires get_by paths through cast_get_by_filter_params consistently.

## Expert (main)
- Umbrella: apps/engine (core), apps/forge (AST/candidates), apps/expert (LSP).
- Completion: Handlers.Completion → CodeIntelligence.Completion.complete/4 → EngineApi → Engine.Completion elixir_sense_expand/1 calls ElixirSense.suggestions/3 DIRECTLY (engine/lib/engine/completion.ex:40) on a PINNED elixir_sense GitHub ref.
- ⚠ NO plugin extension point in Expert itself; whether Spark.ElixirSense.Plugin fires under Expert depends on elixir_sense's plugin discovery — UNVERIFIED, must confirm before planning plugin-based parity. Alternative: inject candidates via Forge.Completion.Candidate + Translatable protocol.
- No dedicated diagnostics handler; build errors via engine/build/error.ex + compilation/tracer.ex.

## Clarity (v0.6.0)
- Introspector behaviour: source_vertex_types/0 + introspect_vertex/2 → {:ok, [entry]} where entry = {:vertex,v}|{:edge,from,to,label}|{:purge,v}; {:error,:unmet_dependencies} re-queues (lib/clarity/introspector.ex:67-102). Registration: config :my_app, :clarity_introspectors.
- Built-in spark/ash introspectors already exist (introspector/ash/resource.ex etc.) — manifest importer = another introspector; scope to span-rich/manifest-only data to avoid duplicating live introspection.
- SourceLocation already converts Spark annos (source_location.ex).

## Tidewave (main)
- Tools hardcoded in raw_tools/0 (mcp/handler.ex:13): Logs+Source+Eval+Ecto; cached in ETS :tidewave_tools. Tool shape: plain maps %{name, description, inputSchema, callback}. No tool_providers exists; hook would extend raw_tools/0 + init_tools/0 — but see upstream-dossier.md: José prefers usage-rules + project_eval; engage PR #215 first.

## Contradictions vs plan
1. Reuse Ash.Info.Manifest IR + JSON serialization; add spans/provenance/IDs as net-new.
2. Embed Spark's existing anno span format, don't invent one.
3. Verify elixir_sense plugin discovery under Expert before Lane C commits to plugin-parity route.
4. Clarity manifest importer must complement, not duplicate, built-in introspectors.
5. Type contracts: Ash emits no @spec for interfaces today; IR (argument_signature, type_resolver) is where type info lives.
