# AshA2ui live diagram rules

Rules for `diagram` entities. See the Live Diagrams topic for the full
contract and a worked `AshBpmn.FlightView` adapter.

## Declaring

- Declare a diagram in the `a2ui` section with a host `source`:

  ```elixir
  diagram :flight do
    label "Visits in flight"
    source MyApp.FlightDiagram          # implements AshA2ui.Diagram.Source
  end
  ```

  `source` may also be `{module, function, args}`, called as
  `apply(module, function, [context | args])`.
- The source returns `{:ok, %{source: mermaid, markers: markers}}` or
  `{:error, reason}`. Markers need `:node_id`, `:label` and `:status`
  (`:active | :executing | :waiting | :failed | :done`). `:initials`,
  `:tone`, `:link`, `:node_label` and `:id` are optional. Give markers a
  stable `:id` (a token or record id).
- Read the host's state in the source through its own authorized reads,
  as `context.actor`. The callback runs on every build and full refresh,
  so keep it to the reads a page load would do.
- Mermaid node ids must match `:node_id`. Use ids mermaid accepts
  (`[A-Za-z_][A-Za-z0-9_]*`, not `end`).

## Links

- Give a marker a link with `link: {"surface_key", record_id}` or
  `link: {MyApp.Resource, record_id}`. It is resolved on the server through
  the `AshA2ui.LinkResolver` (which may veto it) and `:open_surface_url`.
  Never build an href from client input; the client cannot send one.
- In the basic composition, marker links are Buttons only with
  `link_buttons: true`. The handler accepts their `"open_surface"` only for
  a surface the diagram's own markers link to, re-read as the actor.

## Rendering and loading

- The admin catalog (1.4) renders a `liveDiagram` with mermaid at
  `securityLevel: "strict"`. Pass `loadMermaid` to `createAshAdminCatalog`
  and bundle `priv/js/ash_a2ui_mermaid.js` as its own entry, never into
  app.js. Mermaid loads the first time a diagram appears.
- Without `loadMermaid` (or when mermaid fails), and under the basic
  catalog, the diagram renders as a list of nodes with their markers.

## Live updates

- Marker moves are data-model writes to `/diagram/<name>`. With
  `AshA2ui.LiveRenderer`, configure `:pubsub` and subscribe the LiveView to
  your engine's topics; every message triggers a debounced full refresh,
  which calls the source again. Elsewhere, push
  `AshA2ui.Diagram.refresh_messages/2`.

## Avoid

- ❌ Putting domain knowledge (BPMN, lineage) in the surface. Adapt it in
  the source.
- ❌ Sending mermaid source or markers from the client, or trusting a
  client-sent href.
- ❌ Importing `mermaid` into app.js or the catalog bundle.
