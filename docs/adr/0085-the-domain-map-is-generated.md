# ADR 0085 — The domain map is generated

- **Status:** accepted
- **Date:** 2026-11-21
- **Related:** ADR 0021 (the control map is generated), ADR 0009 (first-party packages and the
  ActorContext question), `docs/roadmap.json` and `mix ash_enterprise.roadmap` (the pattern this
  follows)

## Context

The platform spans around twenty first-party and forked packages plus twenty-seven registered
domains, and the only artefacts that described the whole were prose: the ADR index says what was
decided, the ledger says what is proven, but nothing said *what the system is* — which capability
lives where, which bounded context speaks to which, through which edge. A hand-written answer to
that question drifts the moment a domain registers or a package lands: the roadmap task exists
because "a derived artifact that can drift from its source will", and a domain map is the most
drift-prone derived artefact in the repository.

The pieces to build it from already exist and are already machine-readable: `:ash_domains` lists
every registered domain; each domain introspects its resources, and each resource its
relationships; `Ash.Signals.Graph.build/1` maps the declared signal flows; `mix.lock` distinguishes
first-party entries (and knows their pinned revisions). What was missing was an editorial source for
the part no tool can know — which plane a context belongs to, what its mission is, which terms are
its ubiquitous language, which DDD pattern its edges carry.

## Decision

1. **`docs/domain-map.json` is the editorial source.** Planes, contexts (mission, packages, ADRs,
   terms, edges), substrates and adopted packages — exactly the keys the generator validates;
   unknown keys and unknown ids are errors, mirroring the roadmap task's stance. Missions and
   definitions are transcribed from moduledocs, ADRs and the resources' own docs, never invented.
2. **`mix ash_enterprise.domain_map` renders the generated regions of `docs/DOMAIN-MAP.md`.** It
   introspects the registered domains — resources and counts, relationships counted across context
   boundaries, and the declared signal graph — and rewrites the `domain-map:*` regions in place;
   `--check` exits non-zero on drift and runs in CI next to the roadmap check, and in `pre-ci`.
   The task runs under `app.config` + compile and starts neither the application nor the repo
   (iron law #23): introspection reads compile-time declarations only.
3. **Attribution is by domain membership, not `Ash.Resource.Info.domain/1`.** Package-owned
   resources (the compliance catalogs, the projection checkpoints, the process machinery) carry
   their package's domain; the host domain registered in `:ash_domains` is the context they
   actually belong to. The generator maps each registered domain's resources to that domain's
   context.
4. **Two completeness rules are enforced twice** — in the generator and in
   `test/mix/tasks/ash_enterprise_domain_map_test.exs`: every registered domain must have a
   context, and every first-party lock entry must be claimed by a substrate or a context package.
   A context added to the JSON without its `### ` section fails the same way.
5. **Generated cells carry only what the declarations carry.** A resource's row renders its
   `description` when the author wrote one and a dash when they did not; no prose is generated that
   the code does not itself say. Vendor-free prose stays a property of the JSON plus the hand
   sections, not of a sanitizer.
6. **Density is decided up front:** past 45 edges the diagram drops the relationship-count edges
   and renders them as a matrix table under Context relationships. The map currently renders 40 —
   16 editorial edges and 24 introspected relationship edges, 0 declared signal flows (no
   registered resource declares an `emit` or a `signals_in` listener yet; the region renders the
   table the day one does).

## Consequences

The single-document answer to "what is this system" is as current as the code, and wrong in one
place only by being wrong everywhere. Adding a domain without a context, or a first-party package
nobody claims, breaks CI with a message naming what is missing — the same forcing function
`mix ash.codegen --check` provides for schema drift.

What this makes harder: the JSON is now the only place to edit missions, terms and edges, so an
edit that lands in the markdown is reverted by the next generation. That is the roadmap trade-off
again, accepted for the same reason. The introspected tables are only as good as the declarations:
a resource with no `description` renders a dash, and improving the map means improving the
resource, which is where the effort belongs.

## Reversal

Delete `lib/mix/tasks/ash_enterprise.domain_map.ex`,
`test/mix/tasks/ash_enterprise_domain_map_test.exs`, the `domain-map` step from `scripts/pre-ci`,
the workflow step from `.github/workflows/ci.yml`, and the `domain-map:*` regions from
`docs/DOMAIN-MAP.md` — keep the prose sections if the narrative is still wanted. The JSON's
editorial content (missions, terms, edges) can be pasted back into the markdown as plain tables.
About an hour.

## Does it consume ActorContext?

**No — and that is the point of making it generated.** The domain map is a documentation artefact
built from compile-time declarations: `:ash_domains`, resource introspection, the declared signal
graph and `mix.lock`. It runs no actions, reads no rows, and would render identically with an
empty database and no actor. Nothing here can bypass, shadow or second-guess the policy layer,
because nothing here evaluates one; the map *describes* contexts whose every read goes through
`ActorContext`, and the completeness rules keep that description from drifting away from what the
registry actually secures.
