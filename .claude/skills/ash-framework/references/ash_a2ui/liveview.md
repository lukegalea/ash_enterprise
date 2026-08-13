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

Don't rename these events or bypass the handler in a custom
`handle_event/3`.

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

## When not to use it

A plain JSON endpoint returning `AshA2ui.Info.build_surface/2`'s message
list is a complete alternative transport for non-LiveView consumers. Both
are supported; don't invent a third transport before checking the roadmap.
