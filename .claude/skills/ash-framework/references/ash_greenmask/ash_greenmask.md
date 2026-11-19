# Rules for working with AshGreenmask

_Ash extension generating greenmask's pseudoanonymization config from resource
declarations. Derived artefact, never hand-maintained; refuse-by-default; no
runtime._

## The declaration

- The `greenmask do ... end` block is the ONLY place transform knowledge lives.
  Never hand-edit the generated `greenmask.yml` — regenerate it.
- `transform :attr, :transformer, options` names an **attribute**, never a
  column; the generator resolves through `ash_postgres` (`source` honoured).
- `keep :attr, because: "..."` is the only way through unchanged. `because:` is
  mandatory and lands verbatim in the generated header's residuals manifest.
- Every `sensitive?: true` attribute MUST have a `transform` or a `keep`.
  Generation fails otherwise, naming resource + attribute + reason. This is the
  invariant that makes refuse-by-default a property rather than a promise —
  never weaken it to a warning.

- `exclude_data because: "..."` copies the table's schema and none of its rows
  (a hash-chained ledger, a view, credentials). It stands alone in its block.
- Set `config :ash_greenmask, strict?: true` in a host: then a stored resource
  with a `sensitive?` attribute and no block at all also refuses generation.
  Without it such a resource is silently skipped.

## The catalogue is closed

- Transformer names come from `AshGreenmask.Catalogue` only. Adding an entry
  means verifying it against the pinned greenmask binary
  (`greenmask show-transformer <Name>`): name, parameters, allowed column
  types. Greenmask names are CamelCase; DSL names are snake_case.
- Type compatibility is declared per entry and enforced at compile time
  (`:masking` on `:integer` does not compile). Do not widen an entry's type
  list to make a test pass — re-verify against the binary.
- `:cmd` is the escape hatch and stays last-resort: it executes arbitrary
  commands at dump time, and the generated header warns on every use.

## Determinism and the salt

- Determinism comes from greenmask's `Hash` transformer (SHA-3 family,
  `GREENMASK_GLOBAL_SALT` env at dump time). Do not build a second consistency
  mechanism beside it.
- The salt is key material: env-injected at greenmask runtime, never in the
  repo, never in the generated config, never in CI logs.
- Hashed keys can collide (greenmask does not guarantee uniqueness); a
  restore-time FK integrity check belongs to the pipeline, not the package.

## The generated artefact

- `mix ash_greenmask.gen.config` output is committed; CI runs `--check` and
  fails on drift — the same posture as `resource_snapshots/`.
- The header is part of the contract: residuals (what passed through and why),
  `cmd` warnings, the large-objects note, the salt note. Do not strip it.
- The emitter must stay **byte-deterministic**: same declarations, same bytes.
  Never serialize from a map without fixing key order.

## No runtime

- The block compiles to Spark metadata and nothing else. No migration, no
  trigger, no code path in the running application, no database objects.
  A change that adds any of those is the wrong shape for this extension.
