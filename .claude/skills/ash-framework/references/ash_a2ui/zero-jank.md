# Zero jank: perceived latency on A2UI surfaces

The Zero Jank Manifesto (adapted from the generic "Phoenix LiveView Zero
Jank" ruleset — where it conflicts with convenience, the rules win):

- Every interaction must have **<100ms perceived latency**.
- The UI must **always acknowledge input immediately**, even under high RTT.
- The LiveView process is a **coordinator**, not a **worker**.

The generic ruleset was written for host-rendered HEEx. AshA2ui surfaces are
different: their components render **inside shadow DOM** (`@a2ui/lit`), where
`phx-click-loading` classes, `Phoenix.LiveView.JS` commands, and host CSS
cannot reach. Inside a surface, the translation of "optimistic UI" is
**client-side state on the A2UI data model** — never a wait for the server.

## Inside surfaces: instant feedback is client-side

Every interaction with a surface must acknowledge immediately through one of
these mechanisms, in this order of preference:

1. **Optimistic data-model writes** — write the reserved path locally, at
   0 RTT, and let the server's follow-up overwrite it. The shipped hook does
   this for v1.0 actions: the moment an action fires it writes
   `/ui/response = {status: "pending", ...}` (plus `actionId` +
   `wantResponse: true`), the server's `actionResponse` settles it, and a
   watchdog turns a never-answered action into a visible timeout error.
   "Working…" is therefore on screen before the request leaves the browser.
2. **Typed feedback (`/ui/feedback`)** — the v2 handler answers every action
   outcome with `{kind, message}`; components bound to it (the basic `status
   text`, the admin `statusBanner`) render the outcome the moment the
   follow-up lands. The handler always writes it — success, rejection, and
   error paths — so an action never ends silently.
3. **In-flight states on action buttons** — catalog components acknowledge
   clicks themselves: the admin `actionBar` shows `busy` (disabled + spinner)
   while its submit is in flight, and the admin `dataGrid` row-action buttons
   disable + spin from click until the next `/ui/feedback` write settles the
   round trip. No styling round trip, no `phx-*-loading` — the components own
   their shadow DOM.
4. **The bootstrap skeleton** — between LiveView mount and the first
   component tree there is no server HTML to show, so the shipped hook
   renders an immediate skeleton (heading bar + row bars, themed entirely
   with `--a2ui-*` custom properties) inside each surface element at mount,
   and removes it when the first tree renders. No roundtrip is involved: the
   skeleton appears in the same tick the hook attaches.

Related guarantees shipped with the framework:

- **Panel reveal** — when a record-task panel opens (`start_create`,
  `view_record`, `start_edit`), the encoder emits the panel as the **first**
  root component (before tables), and the hook scrolls it into view and
  focuses its first field client-side the moment `/ui/panel/visible` flips —
  instant, no roundtrip. (The admin `recordPanel` additionally manages its
  own focus; the hook stays out of the way when focus already moved.)
- **Debounced PubSub refreshes** (150 ms, coalescing) — data changes fan out
  as incremental `updateDataModel` writes, not full re-renders.

**Reconnect behavior:** the skeleton is a property of the hook mount, not of
the connection. On a LiveView reconnect the hook remounts, the skeleton
reappears, and the fresh bootstrap removes it — a torn-down surface never
shows stale content dressed up as live data.

## What hosts must still do

The classic ruleset applies in full to everything a host renders *outside*
the surfaces — its own LiveViews, layouts, and chrome:

- `phx-*-loading` classes (or JS-command feedback) on every `phx-click` /
  `phx-submit` / `phx-change` control the host renders itself.
- `Phoenix.LiveView.JS` for toggles, modals, and show/hide instead of
  roundtrips.
- `stream/3` (never list assigns) for native lists, and `assign_async` /
  `start_async` for any IO in `mount` / `handle_params` / `handle_event`.
- Keep `actor_fn` / `tenant_fn` light — they run on mount; a slow actor
  lookup blocks the surface bootstrap (it runs inside the async bootstrap
  task, but the skeleton is showing while it does).

The shipped `AshA2ui.ActorPickerLive` follows these rules itself (async
actor read, streamed links, skeleton pills while loading) and is the
reference for host-rendered a2ui chrome.

## Known deviations from the generic ruleset (deliberate)

- **`cancel_record_task` is a roundtrip, not a `JS.hide`.** The panel state
  is a server-enforced state machine (`/ui/panel`), and an optimistic close
  would desync the UI whenever a host rejects the action (e.g. the v1
  experience pin). The transition itself is pure computation, so the round
  trip is RTT-bounded and the v1.0 pending write covers the wait.
- **Action handling runs inline in `handle_event`.** Overlapping invokes on
  one record must apply in order; shunting them into concurrent tasks buys
  process freedom at the cost of write races. The action dispatch is a
  single authorized call (the write itself happens in Ash/ecto), and the
  perceived latency is already masked client-side per the mechanisms above.
- **Lists inside surfaces are data-model paths, not LiveView streams.**
  Streams are a host-rendering tool; inside a surface the renderer owns the
  DOM and updates arrive as incremental `updateDataModel` writes — the same
  discipline (small, keyed, incremental) at a different layer.
- **No `Phoenix.LiveView.JS` inside surfaces** — the equivalent seams are
  data-model writes and catalog component behavior (see 1–4 above).

## Future work (not invented yet, on purpose)

- **A loading counterpart to `emptyState` in the catalog schema.** v2 can
  express "no records" but not "records loading" as a component; adding one
  means a vendored-schema + upstream-renderer change, so slow per-table
  reads (query actions) currently rely on the button in-flight states and
  the typed feedback write — not on a per-position skeleton.
- **Optimistic in-flight styling on the upstream basic-catalog Button** (the
  plain `v0.9.1` + basic-catalog composition) — the basic catalog is
  upstream; AshA2ui surfaces on it rely on the hook's v1.0 pending write and
  the v2 status text binding.
