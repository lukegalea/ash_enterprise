# Draft — GitHub issue for `ash-project/spark`

**Venue:** spark has no Discussions; a regular issue is the RFC venue. **Audience:** zachdaniel (lead) et al.
**Status:** draft for Luke to submit. Nothing here gets posted by anyone else.
**Before posting:** replace `<RFC-LINK>` with the gist/discussion URL, and sanity-check that the
reference to #54 reads correctly against what that issue actually says.

---

## Title

`Proposal: a serialized semantic layer over Spark DSL state — source spans, stable ids, provenance`

---

## Body

### The use case

Four consumers are independently re-deriving Spark's semantics: editor completion
(expert-lsp/expert#826, #475), coding agents, static analyzers, doc exporters. Each loads modules
and introspects in-VM, so each takes its own private dependency on Spark internals.

The one shared path is `lib/spark/elixir_sense/plugin.ex` — 1304 lines probing three host
behaviours with `Code.ensure_compiled/1` and rescuing everything to `:ignore` — plus the churn
around that surface (#54). In expert#475 you said "something far far better than what we have for
ElixirSense is possible." We think the missing piece is an artifact rather than another plugin:
readable without loading the module or agreeing a host API. (#290 is adjacent — the same need for
a queryable view of DSL state.)

### The ask

Extend the direction Ash already started with `Ash.Info.Manifest` into a Spark-level semantic
layer — source spans, stable structural symbol ids, provenance — serialized, versioned, off by
default.

### What exists, and what's missing

- `@spark_dsl_config` holds the full declarative surface post-compile
  (`dsl/extension.ex:654-725`) — complete, but in-VM only.
- Spark already records annotations at three granularities: `section_anno`, `opts_anno`,
  `%Entity.Meta{anno:, properties_anno:}` (`extension.ex:202,231`; `entity.ex:424,449`). Clarity
  consumes them today. **The spans exist; nothing serializes them.**
- `Ash.Info.Manifest` has a JSON serializer and a dump task, but describes the runtime surface
  with no link back to source.

Missing: identity that survives a recompile, so nothing can be referenced across tools or sessions;
a serialized form for consumers in another process; and a record of *which* `use` macro or
transformer put an entity there, so errors can point at the user's line.

Full RFC, with schema and a fixture validated against it: <RFC-LINK>

### Smallest first asks, least intrusive first

1. Infer attribution from the running transformer in `run_transformers/4` (`extension.ex:747`) —
   no call-site change, nothing for extension authors to do.
2. An opt-in emission hook in the existing `@after_verify` phase — and a decision on whether the
   generic layer lives in Spark (so any Spark extension gets it free) or Ash-side only.
3. Whether spans/ids/provenance ride as a `meta` field on the existing IR structs, or as a
   document beside them.

### Non-goals

No new runtime dependencies. No breaking changes — nothing removed or repurposed, serializer output
byte-identical for callers who don't opt in. Emission is opt-in: a project that never asks pays
nothing at compile time. Not a type checker; not a replacement for the `Info` modules in-VM.

### We're already building the consumers

An Expert completion-injection prototype (via `Forge.Completion.Candidate`, since Expert has no
plugin extension point of its own), a Clarity importer as another `Clarity.Introspector`, and an
agent introspection library — all reading the same artifact. We're happy to do the work; we'd
rather agree the format with you first.
