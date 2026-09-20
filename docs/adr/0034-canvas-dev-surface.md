# ADR 0034 — The canvas starts as a dev-only object graph with a naked-object inspector

- **Status:** accepted
- **Date:** 2026-09-09

## Context

The [canvas contract](../plans/2026-09-09-canvas-host-contract.md) — the
library tier of which is `AshA2ui.Canvas` (A2UI-102/103) — describes a
navigable graph of the application's domains, resources and relationships,
with naked-object inspection on selection. The full direction (scenes,
navigation intents, agent context, choreography, record projection) is a
multi-phase build. The first visible slice has to choose where it lives, who
can see it, what the client is allowed to ask for, and what renders the
graph — before any of the later phases exist to validate those choices.

Three verified facts shape the decision. First, this repository already has
a dev-tooling boundary: `/clarity`, `/admin` and the API playground mount
only when `config :ash_enterprise, :dev_routes` is enabled, and nothing else
depends on that flag. Second, `AshA2ui.Canvas` enforces progressive
disclosure by construction: the graph is declared Ash metadata, structural
resolution performs zero record reads (A2UI-103/AC-4), and the resolver has
exactly one fail-closed client-facing verb. Third, the graph is a rendering
problem this application owns client-side: a Cytoscape bundle in the host's
own assets is client-trusted code, in the same sense the A2UI catalogs are —
the server's contract is the payload, not the pixels.

## Decision

Ship the first canvas slice as a **dev-only LiveView at `/canvas`**, inside
the same `if Application.compile_env(:ash_enterprise, :dev_routes)` block
that gates `/clarity` — plus the same signed-in live_session every A2UI
surface uses, because unlike Clarity this inspector *resolves records* under
the viewer's actor and tenant, and an anonymous record-resolution endpoint
would be a hole rather than a demo.

The host contributes three things, all behind the library:

* `AshEnterprise.Canvas.Registry` — every application domain, one list, the
  entire discovery surface (`CANVAS-SEC-005`: what the registry does not
  list does not exist). Audience gating is a later phase and lands here and
  nowhere else.
* `CanvasLive` — builds the graph once on connected mount and pushes it as
  the contract's `canvas:graph` payload; handles exactly one client event,
  `canvas:select`, by resolving one opaque ref through
  `AshA2ui.Canvas.resolve/2` under the signed-in actor and tenant. No other
  client event exists, so there is no client path to records: the payload is
  structural-only and record refs enter through the resolver's authorized
  read or fail closed.
* A **server-rendered HEEx inspector** — deliberately *not* an A2UI surface.
  It shows what the library knows (label, kind, provenance, capabilities
  with consequence/confirmation/authorized?, projections), and turns the
  browse projection into a link to the resource's declared app surface via
  `AshEnterpriseWeb.A2ui.Surfaces` when one exists.

The graph element itself (`<ash-canvas-graph>`, the `AshCanvas` hook,
Cytoscape as the engine with built-in layouts only) is host-side client
assets from the renderer lane: client-trusted presentation of a
server-derived payload, and an accessible tree (`role="tree"`,
`treeitem`s carrying `data-id` + `aria-selected`) as the keyboard,
screen-reader and test surface — the a11y tree is not an overlay on the
canvas, it is the contract the visual canvas must agree with.

## Consequences

**Made easy.** The dev surface is a working end-to-end proof of the Phase D
library before any host commitment beyond one registry list, one LiveView and
one route. The progressive-disclosure guarantee is testable at three layers
(library telemetry, payload shape, absence of record treeitems) and the
fail-closed selection contract at two (ExUnit on the seam, Playwright on the
notice). A second caller — the helper agent asking "what exists?" — can
reuse the registry and resolver unchanged.

**Made hard.** Dev-only means the surface gets no product polish budget and
no audience model; when canvas becomes user-facing, the registry's "all
domains" stance is the first thing that must change, and it is deliberately
the only thing. The inspector being plain HEEx (not an A2UI surface) means
it does not benefit from the admin catalog's theming or the experience
layer's task modes — correct for now, since an inspector of the metadata
layer should not itself be metadata-driven. The branch-pinned `ash_a2ui`
dependency now carries three unmerged PRs; the collapse plan in
[ADR 0033](0033-experience-layer-adoption.md) covers all of them at once.

**Adopted, not written.** Cytoscape is the graph engine the way DMN's
[boxic_dmn](0028-decisions-are-dmn.md) and greenmask are engines: pinned,
client-side, replaceable behind the payload contract. The server never
formats a pixel, so a renderer swap touches only `assets/`.

## Reversal

**To remove the surface:** delete the `if dev_routes` canvas block in the
router, `canvas_live.ex`, `lib/ash_enterprise/canvas/`, the e2e spec, and
the renderer's asset wiring. The library and its registry behaviour are
upstream code this ADR does not remove. No database, no config beyond the
flag that was already there, no data migration — the surface stores nothing.

**To make it non-dev:** the registry gains its audience model (the one
list), the route moves out of the conditional into an authenticated
`live_session`, and the a11y/visual contract carries over unchanged — the
decision that was dev-only was *where it lives*, not what it is.

**The signal to watch:** if the inspector starts growing render logic that
duplicates what the admin catalog's components already do, the "inspector is
not a surface" line has been crossed in the wrong direction — the honest fix
is making the inspector a projection, not growing a second renderer.

## Correction — 2026-09-20: the inspector links more than browse

One mechanism above is superseded by
[ADR 0037](0037-projections-are-host-declared.md).

The Decision says the inspector "turns the browse projection into a link to the
resource's declared app surface via `AshEnterpriseWeb.A2ui.Surfaces` when one
exists". That was the whole routing rule, and it made a node's reachability
depend on whether its page happened to be a derived A2UI table. The process
layer is deliberately not built that way, so every BPMN and decision resource
appeared here as an object with nowhere to go while the application had a page
for each of them.

The inspector now renders one link per projection that has a destination, and
the host declares the projections that action shape cannot reveal — which is
also what finally emits `:diagram`, a kind this ADR named and nothing produced.

Everything else in this record stands: records are still never graph nodes, no
event can request one, the inspector is still server-rendered HEEx rather than
an A2UI surface, and the surface is still dev-only behind the `/clarity` flag.
