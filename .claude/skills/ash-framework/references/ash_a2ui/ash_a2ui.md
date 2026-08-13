# Rules for working with AshA2ui

AshA2ui is an Ash extension that generates A2UI (Agent to UI) protocol
payloads (v0.9.1 or v1.0) from Ash resources. You declare a surface (table +
form + actions) in an `a2ui` DSL block; the extension emits the wire
messages, routes client `action` envelopes back into Ash actions, and
enforces authorization. Read the docs before assuming prior knowledge — the
DSL is small and these rules cover most decisions.

Sub-rules (addressable as `ash_a2ui:<name>`):

- `ash_a2ui:actions` — routing client envelopes through
  `AshA2ui.ActionHandler`, the `row_actions` allowlist, and the reserved
  data-model paths.
- `ash_a2ui:liveview` — the `AshA2ui.LiveRenderer` transport and the JS
  hook wiring contract.
- `ash_a2ui:ag-ui` — the `AshA2ui.AgUi` transport: serving surfaces to
  AG-UI clients (CopilotKit) over SSE, the action round trip, and the
  authentication contract.
- `ash_a2ui:queries` — the `query` entity's server-enforced allowlists for
  search/sort/filter/pagination.
- `ash_a2ui:relationships` — `belongs_to` form selects (inference,
  `option_*` defaults, `/options/<field>`) and `source` table columns.
- `ash_a2ui:layout` — `group` form sections (labeled N-column grids) and
  `row_layout` card-style table rows (title + badge header, metadata grid).
- `ash_a2ui:contexts` — surface `context` entities (server-validated
  selections, dependent options, `context_filter`/`require_context`/
  `select_context`) and `:detail` components.
- `ash_a2ui:dynamic` — agent-composed surfaces (`AshA2ui.Dynamic`): the
  runtime JSON surface spec, the resource allowlist, the server-held
  surface contract, LLM tool integration, and the spec lifecycle
  (serialize/deserialize, diff, promote to a DSL module).
- `ash_a2ui:reports` — `:report` components (aggregate/report queries over
  generic actions) and `export` blocks (CSV file export via the v1.0
  `downloadFile` callFunction).

## Protocol versions

- Each surface declares its wire version with the `spec_version` section
  option (`"0.9.1"` default for compatibility; `"1.0"` recommended for new
  surfaces). `AshA2ui.Dynamic.resolve/2` takes the same value as a
  `:spec_version` option. Everything else in these rules is
  version-agnostic; the DSL does not change.
- What changes on `"1.0"` (full rationale in the `a2ui-1-0` doc topic):
  - Bootstrap is a **single `createSurface`** carrying inline `components` +
    `dataModel` (no `updateComponents`/`updateDataModel` follow-ups, no
    two-phase render flash).
  - Client action envelopes carry a unique `actionId` + `wantResponse: true`
    and the server replies with an **`actionResponse`** — per-action
    success/error feedback instead of only global status paths.
  - Lifecycle + generic-action results consolidate on **`/ui/response`**
    (`{status, message, result, resultText}`) replacing `/ui/status` +
    `/ui/action_result`; the v0.9.1 paths remain only on v0.9.1 surfaces.
  - `theme` becomes `surfaceProperties`; heading Texts are emitted as
    Markdown (`### Title`) instead of `variant` values.
- Both encoders validate against vendored spec schemas
  (`priv/a2ui/v0_9_1/`, `priv/a2ui/v1_0/` — v1.0 is pinned to a spec
  Release Candidate commit; see its NOTES.md).

## When to reach for AshA2ui (preferred ladder)

Work down this ladder and stop at the first rung that fits:

1. **The UI description must cross a wire** (agent canvas, chat surface,
   embedded panel, non-Phoenix client, multiple render targets) and the page
   is a projection of a resource (table/form/actions) → **use AshA2ui**.
2. You need a full internal admin over many resources in a Phoenix app →
   **use AshAdmin**, not AshA2ui. It's less work and renders in-process.
3. The page needs bespoke interactions, custom widgets, or pixel-level
   control → **write plain LiveView** (or use Backpex for Ecto-first admin
   panels). Don't fight the fixed component catalog.
4. Only one Phoenix web client exists and nothing needs to consume a UI
   protocol → plain LiveView; the protocol indirection buys nothing yet.

## Authoring surfaces

- Three authoring modes; pick deliberately:
  - **On the resource** (`use Ash.Resource, extensions: [AshA2ui]` + `a2ui`
    block) — fine for resources that exist to be rendered.
  - **Standalone UI module** (`use AshA2ui.Standalone` + `for_resource` in
    the `a2ui` block) — prefer this for shared domain resources you don't
    want to couple to UI concerns, resources you can't edit, or multiple
    surfaces per resource. Standalone modules are accepted anywhere a
    resource is (`Info`, `ActionHandler`, `LiveRenderer`).
  - **Agent-composed at runtime** (`AshA2ui.Dynamic`) — only for surfaces an
    *agent* designs on the fly from a JSON spec against a host-configured
    resource allowlist. Humans should write the DSL and get compile-time
    diagnostics. Rules in `ash_a2ui:dynamic`.

```elixir
defmodule MyApp.UI.TicketUI do
  use AshA2ui.Standalone

  a2ui do
    for_resource MyApp.Support.Ticket

    component :table do
      fields [:subject, :status]
      read_action :read
      row_actions [:update]
    end

    component :form do
      fields [:subject, :status]
      create_action :create
      update_action :update
    end
  end
end
```

- Section options: `surface_id` (defaults to the underscored short name of
  the resource), `for_resource` (standalone modules only), and
  `add_render_action?` (defaults to `true`; on-resource surfaces get a
  generic `render_a2ui` action returning the surface's messages — set it to
  `false` if you don't want that action on the resource; it is ignored in
  standalone modules).
- Component names are exactly `:table`, `:form`, `:detail`, and `:report`.
  Multiple `:table` components are allowed when each extra one carries a
  distinguishing name (`component :table, :new_items do ... end`); that
  turns the surface multi-table with a scoped data model
  (`/records/<name>`, `/query/<name>`) — see the multi-section-surfaces
  topic before designing one. At most one `:form` per surface. `:detail`
  components render a `context`'s selected record — see
  `ash_a2ui:contexts`. `:report` components render the computed rows of a
  generic action — see `ash_a2ui:reports`.
- When the *set of table sections* is data (one table per runtime bucket/
  category), declare one `:table` template with a `sections` block
  (`source`, `scope_by`, `label`) instead of hardcoding tables — it expands
  at render time into one scoped table per source record, under runtime
  names following the multi-table conventions. `refreshes` naming the
  template key fans out to the whole set (multi-section-surfaces topic).
- Per-cell editing (spreadsheet-style columns) is an `editable` block on
  the table (`fields` allowlist + `update_action`), not a form: cells
  commit through the `"edit_cell"` action, validation errors mirror into
  the failing row's `_error_<field>` key, and v1.0 surfaces get per-cell
  pending→settled feedback via the actionResponse handshake. The editable
  `fields` list is a client-reachable allowlist — keep it minimal.
- Selection-driven screens (pick a record → scope everything else) use
  `context` entities: server-validated pickers, dependent option lists
  (`depends_on`), context-scoped tables (`context_filter` /
  `require_context`), and master/detail (`select_context` + `:detail`).
  Rules in `ash_a2ui:contexts`.
- Table fields may name public **calculations and aggregates** — they load
  (`Ash.Query.load`) and serialize like attributes. They are display-only:
  form fields reject them at compile time (not writable), and only
  aggregates/expression calculations may appear in a query's `sortable`.
- On multi-section surfaces, scope success refreshes with `action` entities
  (`action :approve do refreshes [:new_items] end`) so a row action rewrites
  only its own section; the default refreshes every table.
- **Always declare `row_actions` explicitly and minimally.** It is the
  server-side allowlist for the `invoke` action — anything listed becomes
  invokable by any client that can reach the surface; anything not listed is
  rejected before Ash is called. Never add an action "because it exists".
  Update actions in `row_actions` run **argument-less** on the record
  (touch-style state transitions) — actions needing values belong in the
  form or a generic action with `:record_id` (`ash_a2ui:actions`).
- Omit `fields` only when the inferred set (public attributes for tables,
  action `accept`s for forms) is genuinely what you want shown. Otherwise
  list fields explicitly.
- Use `field` blocks for presentation (`label`, `widget`, `order`, `hidden`,
  `format`) instead of renaming attributes or adding calculated duplicates.
- `belongs_to` form fields (name matching the relationship's
  `source_attribute`) render as selects automatically; `source` field paths
  render table columns through loaded relationships — see
  `ash_a2ui:relationships` before adding calculations or extra attributes
  for either.
- Give tables that need search/sort/filter/pagination a `query` entity and
  keep its allowlists (`search_fields`, `sortable`, `filters`) minimal —
  every entry is client-reachable (`ash_a2ui:queries`).
- Trust the type→widget mapping first (`AshA2ui.TypeMapper`); override with
  `widget` only when the default is wrong for the specific field.
- **Verifier errors are your friend.** Referenced fields and actions are
  checked at compile time; if compilation fails, fix the declaration — do
  not work around it with runtime indirection. A verifier failure means the
  surface would have emitted a broken wire contract.

## Building and serving payloads

- **Never hand-write A2UI JSON.** Always produce messages via
  `AshA2ui.Info.build_surface/2` (full bootstrap: the ordered
  `createSurface` → `updateComponents` → `updateDataModel` list) or
  `AshA2ui.Info.build_data_model/2` (data-only refresh: a single
  `updateDataModel` message). Hand-rolled maps bypass schema validation and
  the versioned encoder.
- Always pass `actor:` (and `tenant:` where relevant). Reads run with
  `authorize?: true`; a nil actor is evaluated by policies as nil, not
  skipped.
- Remember: on a resource with **no policies**, `authorize?: true` is a
  no-op. Transport-level authentication is your only gate there — say so in
  code review rather than assuming enforcement.
- Prefer `AshA2ui.LiveRenderer` for Phoenix hosts (it also gives PubSub live
  refresh) — see `ash_a2ui:liveview`. Use plain JSON endpoints when the
  consumer isn't a LiveView page. Both are supported; don't invent a third
  transport before checking the roadmap.

## Handling client actions

- **Don't bypass `AshA2ui.ActionHandler`.** Every inbound `action` envelope
  goes through `AshA2ui.ActionHandler.handle/3` — it validates the envelope,
  enforces the DSL allowlist, invokes the Ash action with the actor, and
  maps validation errors onto the reserved data-model paths. Calling Ash
  actions directly from transport code skips the allowlist and the error
  mapping. Full contract in `ash_a2ui:actions`.
- Action names are exactly `"submit_form"`, `"select_row"`, `"invoke"`,
  `"prompt"`, `"query"`, `"option_search"`, `"option_select"`,
  `"nested_add"`, `"nested_remove"` (those four only on surfaces with
  searchable selects / nested forms — see `ash_a2ui:relationships`), and
  `"context_search"`, `"context_select"`, `"context_clear"` (only on
  surfaces with `context` entities — see `ash_a2ui:contexts`). Don't
  invent new `action.name` values; add a proper Ash action and expose it
  via `row_actions` instead.
- Row actions that need user input declare `prompt_fields` on their
  `action` entity (Modal prompt; `invoke` then carries a `"values"` map
  filtered + cast to those fields). Per-row availability is `visible_when`
  on the entity — rendered best-effort, but **enforced by the handler on
  every invoke**. Details in `ash_a2ui:actions`.
- **Search/sort/filter/pagination go through a declared `query` entity**
  (see `ash_a2ui:queries`): a named allowlist the server enforces. Never
  accept client sort/filter params not declared in a query, and never feed
  client query input into `Ash.Query` yourself.
- Surface feedback through the reserved data-model paths — `/records`,
  `/form` (nested-form arguments: arrays of row maps), `/errors/<field>`
  for validation errors (nested rows:
  `/errors/<argument>/<index>/<field>`), `/options/<name>` for
  relationship select and picker options, `/select/<name>` for
  searchable-select/picker state,   `/ui/status` for lifecycle feedback,
  `/ui/action_result` + `/ui/action_result_text` for map-returning generic
  actions (raw map + display text, cleared on every subsequent action) —
  on `spec_version "1.0"` surfaces these three consolidate into
  `/ui/response`,
  `/query` for query state (multi-table surfaces scope records and query
  state per table: `/records/<component_name>`, `/query/<component_name>`),
  `/prompt/values/<action>` for prompt Modal state,
  `/context/<name>` + `/detail/<context>` for surface-context selections
  and their detail records
  — never through ad-hoc paths or custom message types. Renderers depend on
  these paths.

## Avoid list

- ❌ Hand-writing or string-templating A2UI message JSON.
- ❌ Calling Ash actions directly from transport code in response to client
  envelopes (bypasses the allowlist — use `ActionHandler`).
- ❌ Wide-open `row_actions` (e.g. mirroring every action on the resource).
- ❌ Treating `authorize?: true` as access control on a policy-less
  resource.
- ❌ Suppressing or working around compile-time verifier errors.
- ❌ Expecting actor-dependent field visibility — v0 has none (documented
  limitation); use separate standalone surfaces per audience instead.
- ❌ Relying on Table components — the v0.9.1 basic catalog has none; tables
  are `List` + `Row`/`Column` composition and AshA2ui handles that for you.
- ❌ Depending on undocumented message batching/ordering details of the
  encoder; only the documented paths and message sequence are contract.
