# Making Ash/Spark First-Class in Elixir Tooling

## Executive answer

The core problem is **not that Ash is intrinsically untypable**. It is that Ash expresses a rich declarative program through Spark macros, accumulates and transforms that program during module compilation, then emits structs, functions, validations, metadata, and code interfaces that most Elixir tools see only incompletely or too late. Spark itself already has a strong internal schema—sections, entities, option schemas, transformers, verifiers, source annotations, and introspection—but today each consumer must rediscover or execute that schema through tool-specific mechanisms.

A serious investment can make Ash's IDE experience substantially better and its public action interfaces much more strictly checked. It cannot, by itself, turn arbitrary Elixir callbacks or Ash expression internals into a Rust/Gleam-style globally sound program: Elixir remains gradual, dynamic escape hatches are intentional, Ash accepts runtime-configured types and extensions, and user callbacks can execute arbitrary Elixir. The viable target is therefore **a first-class typed declarative island with precise generated boundaries**, not “prove every Ash application.”

The strategic mistake would be to patch completion independently in ElixirLS, Expert, Dialyzer, and AI tools. The durable solution is a **versioned, serializable Ash/Spark semantic manifest plus source maps**, consumed by an Expert adapter, generated interface specifications, diagnostics, refactors, documentation, and AI tooling.

## Root causes

### Two languages occupy one file

An Ash resource mixes at least three semantic layers:

1. Ordinary Elixir syntax and runtime semantics.
2. Spark's declarative DSL—sections, entities, options, extension patches, transformers, and verifiers.
3. Ash's domain semantics—resource attributes, action inputs, policies, relationships, calculations, loads, filters, code-interface generation, and data-layer constraints.

The Elixir AST records calls such as `attribute/3`, but does not intrinsically know that this declaration defines a typed field, changes the shape of a resource struct, creates an accepted action input, participates in authorization, or contributes a generated function. That meaning lives in Spark/Ash extension data and transformations. Spark advertises compile-time processing, schema validation, autocomplete, source annotations, introspection, and generated helpers, confirming that the semantic model exists—but outside the compiler's standard AST and type model.

### Expansion happens too late

Ash's useful public surface is partly generated during compilation. A source-only language server sees incomplete syntax; a compiled-code tool sees BEAM abstract code and generated specs, but loses the direct source-level relationship between a declaration and the generated artifact. This creates predictable failures:

- Go-to-definition lands in generated framework code rather than the declaration.
- Rename/find-references does not understand resource-field symbols.
- Hover has generic macro signatures rather than effective action/resource types.
- Diagnostics require compiling or loading extension modules.
- Unsaved and syntactically incomplete buffers cannot be fully expanded safely.
- Macro failures, compile dependencies, or extension side effects can stall editor features.

Rust solves the analogous procedural-macro problem by making macro expansion part of semantic analysis, representing generated pseudo-files explicitly, mapping generated tokens back to source, and isolating procedural macro execution behind a server.[^1][^2] Elixir currently has pieces of the necessary substrate—`Code.Fragment`, incomplete-buffer parsing proposals, scope trees, byte spans, and incremental green/red syntax-tree ideas—but not a complete, shared semantic compiler frontend for IDEs.[^3]

### Dialyzer answers a different question

Dialyzer uses success typing: it seeks definite contradictions and avoids promising that accepted programs are type-safe. Broad specs such as `map()`, `term()`, generic keyword options, and dynamic dispatch therefore erase most of the information that Ash knows. ElixirLS can run Dialyzer incrementally and suggest inferred specs, but it operates after successful builds and depends on compiled abstract code; its original fast integration also used internal Dialyzer APIs.[^4][^5]

Ash's DSL may know that an action requires `%{email: String.t(), role: :admin | :member}`, yet the generated boundary may accept a broad map because casting, defaults, aliases, omitted optional values, unknown-input handling, and runtime errors are part of the action contract. A precise static type and an accepted external input type are not always identical. This is a modeling problem, not just a missing `@spec`.

### Open-world extensibility

Spark lets extensions add sections, entities, DSL patches, types, and transformations. The current completion plugin loads modules, inspects persisted module attributes, executes extension callbacks, parses extension declarations partly with regexes, and rescues failures to `:ignore`. This works pragmatically in ElixirLS/ElixirSense, but it is tightly coupled to those implementations and cannot guarantee deterministic, sandboxed, incremental analysis.

### Dependency topology

Macros and module-body execution establish compile-time dependencies. Ash resources can also accumulate transitive dependencies when callbacks and hooks are written inline. Reports show that moving inline action logic into separate modules can eliminate broad recompilation; Spark has also shipped major runtime/compile-time optimizations and generated fast accessors.[^6][^7] This issue is adjacent to typing but directly affects language-server responsiveness, because completion and diagnostics often need a current build.

## Current state

| Capability | Present state | Main gap |
|---|---|---|
| DSL completion | Spark contains a substantial ElixirSense/ElixirLS plugin for sections, entities, option keys, enum values, types, behaviours, and snippets. | Coupled to changing internal plugin APIs; absent from Expert today. |
| Expert support | Expert has open issues specifically requesting Ash support and parity with Spark's ElixirSense plugin. | No stable framework-neutral semantic extension API or Ash adapter yet. |
| Dialyzer | ElixirLS supports automatic incremental analysis after successful builds.[^4] | Success typing plus broad generated specs cannot express the whole Ash contract. |
| Native Elixir checking | Elixir 1.20 infers whole functions and type-checks all language constructs; the official roadmap still treats user signatures/typed structs as later milestones, and existing Erlang typespecs are considered insufficient for the final set-theoretic signature model.[^8][^9][^10] | Cross-function user-declared set-theoretic contracts and a stable library/plugin API are not yet the mature foundation Ash ultimately needs. |
| Ash typed structs | Ash has actively improved generated constructor checking; issue #2253 proposed function heads that let Dialyzer detect missing required fields and was completed. | This approach does not automatically solve action input maps, loads, relationship state, or extension-defined types. |
| Action boundaries | Code interfaces generate ergonomic public functions and raising/non-raising forms.[^11][^12] | Some semantic/type checks still diverge between interface sugar and explicit actions; for example, `get_by` interface validation remains an open issue. |
| Compilation | Spark has optimized metadata access and compile performance, while application-level inline dependencies remain a known source of rebuilds.[^6][^7] | No standard benchmark suite or IDE-oriented incremental semantic cache. |

The direction of travel is favorable. Elixir's native checker is now much more useful than it was when Ash 2.x/early 3.x design choices were made, but it is still evolving rapidly: pathological type-checking cases have required BDD representation and intersection/difference optimizations, including a reported reduction from 10 seconds to 25 ms for one case.[^13][^14] Building on internal compiler APIs too early would carry real maintenance risk.

## What “strict” can mean

A practical program should define four levels rather than promise a single binary notion of type safety.

| Level | Guarantee | Feasibility |
|---|---|---|
| DSL structural correctness | Valid section/entity/option, allowed values, required options, extension compatibility | High; Spark already owns most metadata and validation. |
| Resource/action interface correctness | Attribute access, action argument names and types, required inputs, return/error/page shapes | High to medium; requires precise generated contracts and accepted-input modeling. |
| Query/load correctness | Relationship paths, calculations, fields, filters, sorts, load-dependent field presence | Medium; requires a first-class load/query type algebra and likely bounded refinements. |
| Arbitrary callback/program proof | All callbacks, dynamic dispatch, runtime extension choices, external side effects | Low without restricting Elixir or moving logic into a statically typed language. |

The most valuable target is levels 1–3. That can surpass typical dynamic-framework tooling and feel comparable to a well-supported TypeScript ORM, even though it does not provide Gleam/Rust's whole-program guarantees.

## Proposed architecture

### Semantic manifest

Introduce a versioned `Spark.SemanticManifest` emitted for each DSL module. It should be stable data, not executable callbacks, and include:

- DSL sections, entities, argument positions, option schemas, docs, deprecations, snippets, and extension provenance.
- Ash resources, attributes, calculations, aggregates, relationships, identities, actions, accepted inputs, defaults, constraints, returns, errors, pagination, authorization metadata, and code interfaces.
- Generated declarations: module/function/arity, overload variants, raising behavior, accepted input type, normalized input type, success type, error type, and deprecation status.
- Symbol IDs and relationships: declaration, reference, generated-from, extension-added, transformed-from.
- Source spans for every symbol and generated artifact.
- Content/version hashes so consumers can invalidate incrementally.

This is the Elixir/Ash analogue of TypeScript declaration files. TypeScript's `.d.ts` files describe exported type surfaces without implementation and can be generated automatically; that separation gives typecheckers and IDEs a cheap, stable artifact.[^15][^16] It also resembles Kotlin Symbol Processing, where processors inspect a stable symbol model and generate source that the regular compiler subsequently compiles.[^17]

### Source maps

Every transformer operation should preserve provenance. If a relationship, generated action, policy field, or interface function originates from a DSL declaration, tooling needs the original URI and range plus a chain of transformations. Without this, diagnostics and navigation will remain framework-shaped rather than user-shaped.

Spark already documents source annotations as a tooling feature, so this is an extension of an existing concept rather than a rewrite. The required step is to make provenance complete, serializable, and tested through transformations and extension patches.

### Pure analysis mode

Provide `Spark.analyze(source, environment, extensions)` with these properties:

- No application start.
- No arbitrary transformer side effects.
- Deterministic output for the same source/dependency manifests.
- Tolerant of incomplete buffers.
- Explicit `unknown` nodes when a value cannot be statically evaluated.
- Time and memory budgets for extension analysis.

Longer term, isolate non-pure extension evaluation in a process, analogous to rust-analyzer's proc-macro server.[^1][^18] A safe first step is a capability split: declarative schemas and pure semantic hooks run in-process; opaque hooks require compiled manifests or sandboxed evaluation.

### Generated type surfaces

Generate two contracts for every action:

1. **Accepted input**: everything the public API will accept before casting/defaulting.
2. **Normalized input/result**: what action code and callers receive after validation.

For example, a UUID input might accept a canonical binary while normalize to Ash's UUID representation. Required inputs should be required map keys; optional inputs should be optional keys rather than “required key with `nil`”; finite constraints should become literal unions when sound. Return types should distinguish `{:ok, value}`, `{:error, Ash.Error.t()}`, pages, bulk results, and bang functions.

This dual-contract model avoids falsely claiming that runtime-cast input is already normalized. It also directly addresses bugs where interface sugar bypasses the same validation path as an explicit action.

### Expert adapter

Porting the existing Spark plugin should be an interim compatibility project, not the final architecture. Expert currently tracks Ash completion as open work and explicitly points to Spark's plugin. The adapter should consume the semantic manifest and the editor's parsed buffer, then implement:

- Completion and signature help.
- Hover with effective types and extension provenance.
- Go-to-definition/implementation.
- Find references and semantic rename for DSL symbols.
- Diagnostics and code actions.
- Semantic tokens, inlay hints, CodeLens, and generated-interface preview.

The adapter must never require Expert to understand every Ash extension. Extension authors should publish semantic data through Spark's protocol.

## Roadmap

### Phase 0: Baseline and contracts — 4 to 6 weeks

- Build a corpus of representative Ash applications: small, large, extension-heavy, incomplete-buffer fixtures, pathological compile graphs, custom types, policies, calculations, and multitenancy.
- Record completion latency, cold/warm diagnostic latency, incremental compile fan-out, memory, false-positive rate, navigation accuracy, and Dialyzer warnings.
- Define the semantic manifest schema, compatibility rules, source-span requirements, and “accepted versus normalized” type vocabulary.
- Establish golden tests comparing DSL declarations, compiled Spark state, generated code, manifest output, and runtime behavior.

**Exit criterion:** a published RFC and reproducible benchmark suite. This phase prevents investment from collapsing into anecdotal editor fixes.

### Phase 1: Expert parity — 6 to 10 weeks

- Implement Expert's Ash support by adapting current Spark completion behavior.
- Cover sections, entities, option keys/values, snippets, extension-added entities, custom Ash types, behaviours, and fragments.
- Add capability/version negotiation instead of probing several internal behaviours as the current plugin does.
- Upstream an explicit Expert plugin interface if maintainers support one; otherwise build a manifest-backed built-in provider.

**Exit criterion:** feature parity with ElixirLS completion on the corpus, p95 completion below an agreed interactive budget, and no project application startup for ordinary completion.

### Phase 2: Manifest and provenance — 8 to 12 weeks

- Add `Spark.SemanticManifest` structs and JSON/ETF serialization.
- Attach stable symbol IDs and source ranges to every DSL entity and transformed/generated declaration.
- Cache manifests per module and invalidate via source and extension hashes.
- Ship `mix spark.semantic` and `mix ash.semantic` inspection commands.
- Add an “expand Ash resource” virtual document comparable to macro-expansion views in Rust tooling.[^1][^19]

**Exit criterion:** Expert can provide completion/hover/navigation from manifests even when dependent resource modules are not loaded in its VM.

### Phase 3: Precise interfaces — 10 to 16 weeks

- Formalize the Ash type algebra independent of Erlang typespec syntax: primitives, literal unions, closed/open maps, required/optional keys, arrays, tagged unions, structs, newtypes, constrained scalars, pages, results, and `dynamic` escape hatches.
- Generate best-possible current `@type` and `@spec` declarations from that algebra.
- Tighten code-interface function heads/specs, with conformance tests against actual casting/defaulting/error behavior.
- Add constructor/check functions for map-shaped action inputs where old typespecs cannot express the required precision.
- Audit every place where interface sugar differs from an explicit action; the still-open `get_by` validation issue is a representative example.

**Exit criterion:** materially improved Dialyzer signal on action call sites with a measured false-positive budget, plus a machine-readable richer type model ready for Elixir's future signature API.

### Phase 4: Diagnostics and refactors — 10 to 14 weeks

- Implement no-build diagnostics for unknown fields/actions, invalid option values, duplicate declarations, impossible policy clauses, invalid relationship/load paths, and missing required action inputs.
- Add safe code actions: create action argument, add accepted attribute, qualify ambiguous field, convert inline callback to module, and replace raw `Ash.*` pipelines with a typed code interface.
- Implement symbol-aware rename/reference indexing across expressions such as filters, sorts, loads, calculations, policies, GraphQL/JSON:API exposure, and migration snapshots.
- Surface compile-dependency hotspots and suggest extracting inline callbacks; real projects report that this can eliminate transitive recompilation.[^7]

**Exit criterion:** useful errors before save/compile and reliable cross-DSL rename for a constrained first symbol set.

### Phase 5: Native type-system bridge — track Elixir releases

- Collaborate with Elixir's type-system team on a supported library/compiler API for generated struct and function signatures.
- Generate native set-theoretic signatures from the same Ash type algebra when the API stabilizes; keep legacy typespec emission as a compatibility backend.
- Test Ash against compiler nightlies and contribute minimized pathological examples. Elixir 1.20's checker has already needed substantial BDD performance work, so large generated resource shapes are valuable stress tests.[^13][^14]
- Avoid tying the manifest to private `Module.Types` internals; those are implementation details and have changed while the checker matures.

**Exit criterion:** native compiler diagnostics cross Ash-generated public function boundaries without duplicating Ash semantics in the compiler.

### Phase 6: Advanced typed queries — 6 to 12 months, experimental

- Model load state: a resource type plus a finite set of loaded relationships/calculations.
- Infer typed filter operands from attribute and relationship paths.
- Add exhaustiveness checking for Ash unions/enums and typed expression operators.
- Explore phantom/refinement-like annotations for `loaded`, `authorized`, `valid`, or `persisted` state, but keep them opt-in until error messages and inference are proven usable.
- Expose the semantic graph through MCP/LSP so coding agents can query “valid actions,” “required inputs,” “relationship path type,” and “references” instead of scraping macros.

**Exit criterion:** demonstrable prevention of common production bugs without excessive annotations or combinatorial type growth.

## Workstreams and priority

| Problem | State of art | Recommended investment | Priority |
|---|---|---|---|
| Spark DSL completion | Existing rich ElixirSense plugin; Expert parity issues open. | Port now, then replace internals with manifest consumption. | P0 |
| Stable semantic API | Spark owns rich schemas/introspection but no universal serialized IR. | Design and standardize manifest + source maps. | P0 |
| Action/interface typing | Generated interfaces exist; targeted constructor/spec improvements occur; semantic gaps remain.[^11] | Dual accepted/normalized types and contract conformance tests. | P0 |
| Diagnostics before build | Current plugins rely heavily on parsed fragments plus loaded modules. | Pure, tolerant semantic analysis and cached dependency manifests. | P1 |
| Navigation/refactors | Generic LSP sees macro calls, not Ash symbols. | Symbol IDs, provenance graph, rename/reference index. | P1 |
| Incremental performance | Spark optimizations helped; module-body dependencies still cause fan-out.[^6][^7] | Benchmarks, cache keys, isolated extension execution, dependency diagnostics. | P1 |
| Native strict typing | Elixir's checker now infers whole functions but user signature design remains a moving target.[^8][^10] | Collaborate/upstream; do not fork a competing full checker. | P1, release-gated |
| Typed load/query state | No mature Elixir solution; static languages use generics/refinements/codegen. | Experimental library layer after foundations. | P2 |
| Whole-program strictness | Gleam achieves it by constraining the language and omitting Elixir-style macros.[^20][^21] | Explicitly out of scope for arbitrary Elixir. | Not a primary goal |

## Lessons from other ecosystems

### TypeScript: declaration surfaces

TypeScript separates implementation from a compact exported declaration surface. `.d.ts` files contain types without executable bodies, can ship with packages, and are efficiently consumed by both checker and IDE.[^15][^16] Ash should copy the **separation and stability**, not TypeScript's exact syntax: the Spark/Ash manifest is the declaration file, while adapters translate it into current typespecs, future Elixir signatures, OpenAPI/GraphQL schemas, and LSP symbols.

The warning is drift. Handwritten declaration files can disagree with implementations, so Ash should generate them from the exact semantic state used to generate runtime interfaces and verify them against behavior.[^22]

### Rust: macro-aware semantic analysis

Rust treats macro output as part of the source universe, gives generated expansions pseudo-file identities, integrates expansion with name resolution, and isolates procedural macro execution.[^1][^18] Ash needs the same three ideas: explicit expansion artifacts, bidirectional source mapping, and process isolation. Reimplementing arbitrary macros in the language server is not scalable.

### Kotlin: symbols and compiler plugins

KSP exposes a stable symbol-processing API, deliberately limits what processors can inspect, and compiles generated sources with normal sources.[^17] Kotlin FIR also has a declaration-generation extension designed so generated declarations can be understood by compiler and, increasingly, IDE infrastructure.[^23] Spark should similarly specify a restricted, stable semantic extension contract rather than grant tools arbitrary transformer execution.

### Erlang checkers

Gradualizer checks bodies and call sites against declared specs but mostly relies on those specs rather than whole-program inference.[^24][^25] eqWAlizer demonstrates that stricter, scalable checking on the BEAM is possible when functions have signatures, but comparative research notes that it performs local analysis on signed functions and does not analyze unsigned functions.[^26] Both reinforce the same conclusion: precise generated Ash boundaries are high leverage, but they do not eliminate dynamic interior code.

### Gleam: constrain the language

Gleam obtains sound static inference and exhaustive ADTs by designing a smaller language without Elixir macros and many dynamic facilities.[^20][^21] A Gleam-like guarantee for arbitrary Ash callbacks would require a restricted callback DSL or a typed companion language. A viable later experiment is to generate a typed client/domain façade in Gleam or another typed representation, but that is an interop strategy, not a replacement for improving Elixir tooling.

## Investment model

A credible initial program is a **small senior tooling team for 9–12 months**:

- One Elixir compiler/LSP engineer.
- One Ash/Spark core engineer.
- One type-systems/static-analysis engineer, potentially fractional after the type algebra is established.
- Maintainer time from Expert and Elixir for design reviews and upstream APIs.

The first 3–4 months should fund P0 foundations and Expert parity; continued funding should depend on measured adoption and diagnostic precision. A separate full Elixir type checker is not recommended: the native compiler effort has momentum, and maintaining a competing frontend would consume the budget before Ash-specific value appears.[^8][^10]

Governance matters. Put the semantic manifest and conformance suite under Spark/Ash, keep LSP adapters thin, publish an extension-author contract, version the schema, and fund upstream work instead of carrying private patches. This creates infrastructure reusable by Reactor and other Spark DSLs rather than an Ash-only editor plugin.

## Principal risks

- **Compiler API churn:** native type internals are changing; mitigate with an independent semantic IR and backend adapters.
- **Unsound promises:** casting and runtime extensions can make simple specs lie; mitigate with accepted/normalized contracts and explicit `dynamic` fallbacks.
- **Extension impurity:** arbitrary compile-time code hurts determinism and security; mitigate through pure hooks, cached manifests, and process isolation.
- **Type explosion:** relationship/load refinements and large literal unions can produce huge set-theoretic terms; mitigate with widening thresholds and opaque aliases. Elixir's recent pathological checker optimizations show this risk is real.[^13][^14]
- **Maintainer fragmentation:** supporting ElixirLS and Expert independently doubles work; treat ElixirLS compatibility as maintenance and Expert/manifest as the forward path.
- **False-positive erosion:** strictness that developers routinely suppress has negative value; every diagnostic family needs corpus-based precision measurement and an escape hatch.

## Recommendation

Proceed, but define the product as **Ash Semantic Tooling**, not “better Dialyzer support.” The highest-return sequence is:

1. Expert parity and benchmarks.
2. A stable Spark/Ash semantic manifest with source maps.
3. Precise generated action/resource contracts.
4. Build-free diagnostics, navigation, rename, and code actions.
5. A backend for Elixir's native set-theoretic signatures when its public API stabilizes.
6. Experimental typed loads and expressions only after the foundation proves fast and accurate.

This program can plausibly give Ash a better domain-aware authoring experience than conventional Elixir code and a level of boundary checking comparable to strong TypeScript framework tooling. It cannot make unrestricted Elixir as statically safe as Gleam or Rust; achieving that would require restricting the programming model. The architecture above captures most of the practical benefit without sacrificing Ash's extensibility or Elixir's dynamic strengths.

---

## References

1. [Macro Expansion | rust-lang/rust-analyzer | DeepWiki](https://deepwiki.com/rust-lang/rust-analyzer/5.2-macro-expansion) - Macro expansion in rust-analyzer is the process of resolving and expanding Rust macros (declarative ...

2. [What Every Rust Developer Should Know About Macro ...](https://blog.jetbrains.com/rust/2022/12/05/what-every-rust-developer-should-know-about-macro-support-in-ides/) - We use a lot of tools for software development. Compilers, linkers, package managers, code linters, ...

3. [Environments for code fragments/buffers (i.e. elixirsense) · Issue #12645 · elixir-lang/elixir](https://github.com/elixir-lang/elixir/issues/12645) - Hi everyone, This is as second take on "building environments for code fragments" for IDEs (follow u...

4. [elixir-lsp/elixir-ls: A frontend-independent IDE "smartness ... - GitHub](https://github.com/elixir-lsp/elixir-ls) - A frontend-independent IDE "smartness" server for Elixir. Implements the "Language Server Protocol" ...

5. [GitHub - lukaszsamson/elixir-ls-1: A frontend-independent IDE "smartness" server for Elixir. Implements the "Language Server Protocol" standard and provides debugger support via the "Debug Adapter Protocol"](https://github.com/lukaszsamson/elixir-ls-1) - A frontend-independent IDE "smartness" server for Elixir. Implements the "Language Server Protocol" ...

6. [Recent Spark performance improvements should have significant positive effects on Ash application performance | Elixir Forum](https://elixirforum.com/t/recent-spark-performance-improvements-should-have-significant-positive-effects-on-ash-application-performance/59076/) - Hey folks, made some recent performance improvements to spark, the tool underlying all of our DSLs. ...

7. [Reducing incremental compilation times in Phoenix/Ash project | Elixir Forum](https://elixirforum.com/t/reducing-incremental-compilation-times-in-phoenix-ash-project/72113/) - So I’m building a couple of projects with Elixir/Ash/Phoenix/Inertia/React and I’m being EXTREMELY p...

8. [Gradual set-theoretic types — Elixir v1.17.1 - Hexdocs](https://hexdocs.pm/elixir/1.17.1/gradual-set-theoretic-types.html)

9. [Gradual set-theoretic types — Elixir v1.18.0](https://hexdocs.pm/elixir/1.18.0/gradual-set-theoretic-types.html)

10. [elixir/CHANGELOG.md at main · elixir-lang/elixir](https://github.com/elixir-lang/elixir/blob/main/CHANGELOG.md) - Elixir is a dynamic, functional language for building scalable and maintainable applications - elixi...

11. [Ash.CodeInterface — ash v3.6.2](https://hexdocs.pm/ash/Ash.CodeInterface.html)

12. [Code Interface — ash v2.11.4](https://hexdocs.pm/ash/2.11.4/code-interface.html)

13. [Lazy BDDs with eager literal intersections](https://elixir-lang.org/blog/2026/02/26/eager-literal-intersections/) - This article explores the latest batch of optimizations we did to set-theoretic types and their repr...

14. [Lazy BDDs with eager literal differences](https://elixir-lang.org/blog/2026/03/19/lazy-bdds-with-eager-literal-differences/) - This is a follow up to our batch of set-theoretic types optimizations, this time targeting differenc...

15. [Built-in Type Definitions](https://www.typescriptlang.org/docs/handbook/2/type-declarations.html) - How TypeScript provides types for un-typed JavaScript.

16. [Documentation - TypeScript 5.5](https://www.typescriptlang.org/docs/handbook/release-notes/typescript-5-5.html) - TypeScript 5.5 Release Notes

17. [Kotlin Symbol Processing API](https://kotlinlang.org/docs/ksp-overview.html)

18. [Proc macro support in rust-analyzer for nightly rustc versions](https://fasterthanli.me/articles/proc-macro-support-in-rust-analyzer-for-nightly-rustc-versions) - I don’t mean to complain. Doing software engineering for a living is a situation of extreme privileg...

19. [Structuring, testing and debugging procedural macro crates](https://ferrous-systems.com/blog/testing-proc-macros/) - In this blog post we'll explore how to structure a procedural macro, AKA proc-macro, crate to make i...

20. [Gleam for Erlang developers: type-safe language for the ...](https://botmonster.com/coding/gleam-erlang-developers-type-safe-beam-vm/) - Gleam brings statically-typed functional programming to the BEAM VM with Hindley-Milner inference, E...

21. [Gleam · LangIndex](https://langindex.dev/languages/gleam/) - Gleam is a statically typed functional language for the Erlang VM and JavaScript runtimes, centered ...

22. [Generation of TypeScript Declaration Files from JavaScript Code](https://arxiv.org/pdf/2108.08027.pdf) - ...TypeScript applications integrate
JavaScript libraries via typed descriptions of their APIs calle...

23. [kotlin/docs/fir/fir-plugins.md at master · JetBrains/kotlin](https://github.com/JetBrains/kotlin/blob/master/docs/fir/fir-plugins.md) - The Kotlin Programming Language. . Contribute to JetBrains/kotlin development by creating an account...

24. [gradualizer v0.2.0](https://gradualizer.hexdocs.pm/gradualizer.html)

25. [GitHub - josefs/Gradualizer: A Gradual type system for Erlang](https://github.com/josefs/Gradualizer) - A Gradual type system for Erlang. Contribute to josefs/Gradualizer development by creating an accoun...

26. [Same Same but Different: A Comparative Analysis of Static Type Checkers in Erlang](https://dl.acm.org/doi/pdf/10.1145/3677995.3678189)

