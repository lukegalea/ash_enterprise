# Canvas host surface — lane contract

> **Status: contract for the dev-only `/canvas` surface.** Written before
> implementation. Two lanes build against this file concurrently:
> the **host wiring lane** (Elixir: registry, route, LiveView, inspector,
> tests, ADR — owns `lib/`, `config/`, `test/`, `docs/`, `mix.exs`) and the
> **renderer lane** (owns `assets/**` including `package.json` and
> `app.js`). Neither lane touches the other's scope.

## What this surface is

The first visible slice of the AshCanvas direction (TRD): the host's
domains, resources and relationships as a navigable object graph, with
server-resolved naked-object inspection on selection. **Dev-only**
(the `/clarity` precedent). It demonstrates the Phase D library
(`AshA2ui.Canvas`, PR #3) — no scenes, no agent, no records in the graph.

## Dependency

`mix.exs` pins `ash_a2ui` to branch `feat/a2ui-stack` (integration ref
combining PRs #1+#2+#3; collapses to a tag once they merge).

## Element, hook, and events (pinned — do not rename)

- **Custom element**: `<ash-canvas-graph>` (Lit, host assets).
- **LiveView hook**: `AshCanvas`, registered in `assets/js/app.js`,
  mounted as `<div id="canvas-graph" phx-hook="AshCanvas" phx-update="ignore">`.
- **Server → client** (once on mount): `push_event("canvas:graph", %{
  "revision" => String.t(), "nodes" => [...], "edges" => [...] })` where
  nodes are `%{"id" => id, "kind" => "application"|"domain"|"resource",
  "label" => label, "metadata" => map}` and edges are `%{"kind" =>
  "contains"|"relationship", "from" => id, "to" => id, "name" => name}` —
  the JSON form of `AshA2ui.Canvas.Graph` (see
  `~/ash_a2ui/.slim/worktrees/canvas/lib/ash_a2ui/canvas/graph.ex` for the
  source of truth).
- **Client → server**: the hook sends `pushEvent("canvas:select",
  {"ref": "<object_ref_id>"})`; the LiveView handles
  `handle_event("canvas:select", %{"ref" => ref})` by calling
  `AshA2ui.Canvas.resolve(ref, registry: <host registry>, actor:, tenant:)`
  and re-rendering the inspector.
- **No other client events exist.** In particular there is no way to
  request records — progressive disclosure is enforced server-side
  (`A2UI-103/AC-4`): the graph payload contains structural nodes only.

## Accessibility + DOM contract (renderer lane owns; Playwright asserts it)

- The element renders an accessible **tree** alongside the visual canvas:
  `role="tree"` with `role="treeitem"` entries carrying `data-id` (the node
  id) and `aria-selected` reflecting selection. This tree is the keyboard
  and screen-reader surface AND the Playwright assertion surface
  (locators pierce shadow DOM).
- Canvas region: focusable (`tabindex="0"`, labeled), arrow keys move
  selection between adjacent nodes, Enter confirms selection (dispatches
  `canvas:select`), Escape clears.
- Visual canvas: distinct styling per node kind (application / domain /
  resource), containment hierarchy legible top-down, relationship edges
  visually distinct from containment, selected node highlighted, pan/zoom
  via mouse and explicit Fit control, `prefers-reduced-motion` respected
  (no animated layout transitions), handles container resize.
- Cytoscape is the graph engine (`cytoscape` npm dep, host-side — the
  renderer is client-trusted per the TRD). Built-in layouts only
  (e.g. breadthfirst/cose); no extra layout packages.

## Inspector (host wiring lane; server-rendered HEEx, NOT an A2UI surface)

On selection the LiveView shows, from the resolved `AshA2ui.Canvas.Object`:
label + kind badge, provenance (domain/resource display names as plain
text), capabilities (label, consequence, confirmation, authorized?),
projections (declared kinds). When the resource has a declared app surface
route (check `AshEnterpriseWeb.A2ui.Surfaces`), the browse projection
renders as a link to it. Unknown/malformed refs render an inline
"unknown object" notice (the resolver's fail-closed error) — never an
error leak.

## Registry

`AshEnterprise.Canvas.Registry` implements the `AshA2ui.Canvas.Registry`
behaviour over the application's domains (all of them — this is the dev
surface, same visibility as Clarity; audience gating is a later phase).

## Route

Dev-only `/canvas` following the exact dev-route gating `/clarity` uses
in the router. LiveView named `CanvasLive` under
`AshEnterpriseWeb` dev scope.

## Evidence expected

- ExUnit: registry completeness (every app domain/resource appears in the
  built graph), route gating (dev-only), select event resolves + renders
  inspector content, graph payload contains zero record nodes.
- Playwright (`assets/e2e/canvas_graph.spec.ts`): logged-in `/canvas`
  renders the tree with domain + resource treeitems; clicking (and
  keyboard-selecting) a resource treeitem shows the inspector with label,
  capabilities, projections; no record treeitems exist; axe scan of the
  canvas surface has zero serious/critical violations.
- ADR 0034 (`docs/adr/0034-canvas-dev-surface.md`): dev-only boundary,
  library dependency (PR #3 / stack ref), Cytoscape host-side decision,
  progressive-disclosure guarantee, a11y tree contract.

## Correction — 2026-09-20: projections are host-declared, and links are plural

Two statements above describe a contract that has since widened.

**"When the resource has a declared app surface route … the browse projection
renders as a link to it."** That was the whole of the routing rule, and it made
a node's reachability depend on whether its page happened to be a derived A2UI
table. The process layer is deliberately not built that way — a BPMN diagram is
bpmn-js, an approvals list is an indexed candidate query — so every BPMN and
decision resource appeared in the graph as an object with nowhere to go, while
the application had a page for each of them all along. The inspector now renders
one link per projection that has a destination, and a resource with a host route
but no A2UI surface gets one.

**"projections (declared kinds)"** understates what the host may say. Projections
were derived purely from action shape, which cannot distinguish a process
definition from a business unit: their actions are identical, and what differs is
that this application draws one of them. `AshA2ui.Canvas.Registry.projections/2`
(added upstream, `ash_a2ui` 825f327) lets the host choose among the declared
kinds; the vocabulary stays the library's, so the host cannot introduce a
projection the experience compiler has no meaning for. See
[ADR 0037](../adr/0037-projections-are-host-declared.md).

What has *not* changed: records are still never graph nodes, no event can request
one, and audience gating is still a later phase. The registry remains the single
place that decision will land.
