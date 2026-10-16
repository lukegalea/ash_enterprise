# LiveView transport (AshA2ui.LiveRenderer)

`AshA2ui.LiveRenderer` is the batteries-included Phoenix transport. It is
only compiled when `phoenix_live_view` is present — the protocol core
(DSL -> encoder -> `ActionHandler`) works without Phoenix.

## Defining the LiveView

```elixir
defmodule MyAppWeb.TicketA2uiLive do
  use AshA2ui.LiveRenderer,
    ui: MyApp.UI.TicketUI,
    actor_fn: & &1.assigns.current_user
end
```

That is the entire LiveView. `use` options:

- `:ui` (required) — the resource or `AshA2ui.Standalone` UI module whose
  `a2ui` section defines the surface.
- `:actor_fn` (optional) — 1-arity `socket -> actor`, evaluated on mount;
  the actor is passed to every surface, data-model, and action call.
  Without it every Ash call runs with a nil actor.
- `:tenant_fn` (optional) — 1-arity `socket -> tenant`, same semantics.
- `:pubsub` (optional) — enables live refresh:
  `pubsub: [module: MyApp.PubSub, topics: ["tickets:created", ...]]`.
  Topics are explicit configuration — list the topics your resource's
  `Ash.Notifier.PubSub` notifier publishes; the extension does not
  introspect them.

All injected callbacks (`mount/3`, `render/1`, `handle_event/3`,
`handle_info/2`) are `defoverridable`. If your LiveView receives unrelated
messages while `:pubsub` is configured, override `handle_info/2` —
otherwise any message is treated as a data-change signal and coalesced into
a debounced (150 ms) `AshA2ui.Info.build_data_model/2` refresh.

## Wire events (contract with the JS hook)

- Server -> client: messages are pushed as the `"a2ui:messages"` event with
  payload `%{messages: [...]}`.
- Client -> server: the hook pushes the `"a2ui:action"` event carrying the
  A2UI v0.9.1 client envelope; the LiveView routes it through
  `AshA2ui.ActionHandler.handle/3` and pushes the follow-up messages for
  both ok and error results.

- Client -> server: `"a2ui:open_surface"` with `%{"surface", "recordId",
  "query"}` when a reference link is activated. The default handling
  `push_navigate`s to the `:open_surface_url` option (or `config :ash_a2ui,
  :open_surface_url`, `{surface}`/`{recordId}` placeholders); pass
  `open_surface: &MyLive.open/2` (`(args, socket) -> {:noreply, socket}`)
  to stack surfaces or anything else. The target is always built
  server-side — never trust a client href.
- Basic-catalog reference links arrive as an `"a2ui:action"` named
  `"open_surface"` (context `%{"field", "surface", "recordId"}`). The
  handler validates the field/surface pair (not the record id) and
  returns no messages; on `{:ok, _}` the LiveRenderer navigates through
  the same `:open_surface` / `:open_surface_url` path. The LiveRenderer
  builds with `link_buttons: true` only when it has one of those two, so
  a LiveView that cannot navigate shows plain link text.

Don't rename these events or bypass the handler in a custom
`handle_event/3`.

## Deep links

- The connected mount reads `?ctx[<context>]=<id>` (validated through
  authorized reads, labels derived server-side) and `?q[...]` (the
  `/query` state, allowlist-validated) into the bootstrap.
- `deep_link: true` injects `handle_params/3` (router-mounted LiveViews
  only): context changes `push_patch` the `ctx` params (other params
  kept) and back/forward re-applies them. Hosts that wrap
  `AshA2ui.LiveRenderer.mount/4` themselves must pass the real `params`.

## JS hook wiring (host bundle responsibilities)

The shipped hook (`priv/js/ash_a2ui_hook.js`) has **no npm dependencies of
its own** — the host app bundle must supply the `@a2ui` renderer classes
before the LiveSocket mounts the hook:

```javascript
import {MessageProcessor} from "@a2ui/web_core/v0_9";
import {basicCatalog} from "@a2ui/lit/v0_9";  // also registers <a2ui-surface>
import {AshA2ui, configureAshA2ui} from "ash_a2ui/priv/js/ash_a2ui_hook.js";

configureAshA2ui({MessageProcessor, catalogs: [basicCatalog]});
const liveSocket = new LiveSocket("/live", Socket, {hooks: {AshA2ui}});
```

Forgetting `configureAshA2ui({MessageProcessor, catalogs})` is the most
common wiring mistake — the hook throws on mount with an explanatory error.
(`globalThis.__ASH_A2UI_DEPS__` is an equivalent fallback for separately
bundled hooks.)

For production-quality surfaces, prefer the full wiring (see the Theming
topic and the docs in the shipped JS files):

- pass `markdown: {ContextProvider, context: Context.markdown, render:
  renderMarkdown}` (from `@lit/context`, `@a2ui/lit/v0_9` and
  `@a2ui/markdown-it`) to `configureAshA2ui` — otherwise Text headings
  render as literal `## ...` markdown;
- pass the merged catalog from `priv/js/ash_a2ui_catalog.js`
  (`createAshA2uiCatalog(deps)`) instead of `basicCatalog`, so
  single-choice ChoicePickers render as native `<select>`s (never pass
  both — they share the same catalog id and the first match wins);
- import `priv/js/ash_a2ui_theme.css` into the app CSS and override the
  `--a2ui-*` variables with the app's design tokens (the components render
  in shadow DOM — CSS variables are the only styling seam; Tailwind
  classes cannot reach them).

The rendered container is
`<div id="ash-a2ui-surface" phx-hook="AshA2ui" phx-update="ignore">` —
`phx-update="ignore"` is required; the renderer owns that DOM.

v0 limitation: one surface per hook instance.

## Optional host-side pieces

These ship with the package but are opt-in; none of them changes the wire.

- **Presence** (`AshA2ui.Presence` + `AshA2ui.PresenceBar`): who else is on
  a surface, as an avatar stack. `use AshA2ui.Presence, pubsub_server:
  MyApp.PubSub` in a host module, add it to the supervision tree, call
  `AshA2ui.Presence.mount_surface/4` in mount (`key:` a stable identity,
  `label:` the display name), route `handle_info` through
  `AshA2ui.Presence.handle_broadcast/3`, and render
  `<AshA2ui.PresenceBar.bar presences={@a2ui_presences} />`. Tracking is per
  surface id; it rides the surface's own topic.
- **Combobox wiring** (`AshA2ui.Combobox.ids/1`): the merged catalog upgrades
  context pickers and searchable selects into a typeahead combobox by
  matching the emitted id contract. A host hook that needs to find those
  composites gets the ids from `ids(context: name)` /
  `ids(field: name, searchable: true)` instead of hand-writing them.
- **NB components** (`priv/js/nb_components.js`, `defineNbComponents()`):
  dependency-free custom elements (`nb-menu`, `nb-sheet`, `nb-tabs`,
  `nb-table`, `nb-calendar`, `nb-pagination`, …) for host-rendered chrome
  around surfaces, themed by the same `--a2ui-*` variables. They are host
  primitives, not catalog components — never emit them in surface payloads.
- **Canvas** (`AshA2ui.Canvas`): a structural graph of the host's registered
  domains (`build_graph/1`) and opaque object refs resolved with the actor
  (`resolve/2`, server-derived capabilities). The host implements
  `AshA2ui.Canvas.Registry`; what it does not list does not exist. Never
  turn a client-supplied string into a module or atom to reach it.

## When not to use it

A plain JSON endpoint returning `AshA2ui.Info.build_surface/2`'s message
list is a complete alternative transport for non-LiveView consumers. Both
are supported; don't invent a third transport before checking the roadmap.
