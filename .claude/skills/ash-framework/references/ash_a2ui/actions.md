# Actions: routing client envelopes into Ash

Every inbound A2UI `action` envelope must go through
`AshA2ui.ActionHandler.handle/3`. It validates the envelope, enforces the
DSL allowlist, invokes the Ash action with the actor, and maps errors onto
the reserved data-model paths. Calling Ash actions directly from transport
code skips all of that.

## `handle/3` contract

```elixir
AshA2ui.ActionHandler.handle(resource_or_ui_module, envelope,
  actor: current_user,
  tenant: tenant          # optional
  # authorize?: true      # the default — leave it on
)
# => {:ok, [updateDataModel, ...]} | {:error, [updateDataModel, ...]}
```

- The first argument is a resource using the `AshA2ui` extension or an
  `AshA2ui.Standalone` UI module — the same module you pass to
  `AshA2ui.Info.build_surface/2`.
- The envelope may be the full client->server message
  (`%{"version" => ..., "action" => %{"name" => ..., "context" => ...}}`)
  or a bare inner action map — both are accepted.
- Push the returned messages to the client **for both `{:ok, _}` and
  `{:error, _}`** — error messages carry the validation feedback the
  renderer must display.

## The task panel

Every surface with a `:form` component composes a record task panel: a
three-mode machine (browse, create, view, edit) over the form buffer, with
its state at `/ui/intent` and `/ui/panel/*`. The encoder emits the
affordances; the handler owns the transitions:

- `"start_create"` — context `%{}`. Opens the panel in create mode over a
  fresh `/form` (intent `"create"`, primary label `"Create <Resource>"`).
  Rejected when the surface declares no create action. The emitted
  `create_button` only appears when a create action is declared, and never
  under a related table.
- `"view_record"` — context `%{"recordId" => id}`. An authorized read of the
  record, rendered **read-only** at `/ui/panel/record/<field>` (intent
  `"view"`). `/form` is never written and no submit is offered; Cancel is
  the only exit. The `view_button` row control appears only on surfaces
  with a form, and only on tables over the surface's own resource.
- `"start_edit"` — context `%{"recordId" => id}`. Rejected unless the
  surface declares an `update_action`. Pre-flights the update authorization
  (`Ash.can?`) so the panel never opens on a write the server would refuse,
  then populates `/form` with the record's values (including `"id"`, nested
  form rows and `/select` labels) in edit mode (primary label
  `"Save changes"`). The `edit_button` row control follows the same gates.
- `"cancel_record_task"` — context `%{}`. Back to browse: panel closed,
  `/form` and `/errors` reset, feedback cleared.

A successful `submit_form` closes the panel and returns to browse; a failed
one keeps the mode, the panel and the submitted values for correction.
Related tables (a `:table` with its own `resource`) are read-only: they get
neither the View/Edit controls nor the create button. Their master/detail
hook is `select_context`, whose row button reads "Select <context>".

## The core action names

The core envelope names are `"submit_form"`, `"invoke"`, `"prompt"`,
`"query"` and the four task-panel actions above. Feature-specific names exist only when the
surface declares the feature: the context actions (`ash_a2ui:contexts`),
the relationship-picker actions (`ash_a2ui:relationships`), `"edit_cell"`
(tables with an `editable` block — commits one field of one record through
the declared update action, with validation errors mirrored into the
failing row's `_error_<field>` key), `"report"` (`:report` components —
runs the declared generic action; `ash_a2ui:reports`), `"export"`
(components with an `export` block — answers with the `downloadFile`
callFunction; `ash_a2ui:reports`), `"bulk_invoke"` / `"bulk_select"`
(tables with `bulk_actions` — see "Bulk actions" below) and `"wizard_next"` /
`"wizard_back"` (forms declaring `step`s — Next builds the form action's
changeset over the carried `/form` through the same path `submit_form` writes
with, without submitting it, and keeps only errors of reached steps; both
rewrite `/ui/wizard` and the panel's primary label and submit gate;
`ash_a2ui:layout`) and `"open_surface"` (opt-in basic-catalog reference
links — the field/surface pair is validated against the surface's to-one
link fields, the record id is not; no messages, the transport navigates;
`ash_a2ui:relationships`). Don't invent new
`action.name` values;
add a proper Ash action and expose it via `row_actions` instead.

- `"submit_form"` — context `%{"values" => %{...}, "recordId" => id | nil}`.
  No `recordId` runs the form's create action; with one, the update action.
  String-keyed values are cast against the target action's accepted
  attributes/arguments (no dynamic atom creation); unknown keys are silently
  dropped.
- `"invoke"` — context `%{"action" => name, "recordId" => id | nil}` (plus
  an additive `"component" => table_name` identifying the source table; the
  handler tolerates its absence). **The named action must be listed in the
  surface's `row_actions`** — that list is the server-side allowlist and the
  authorization surface for client-triggered actions. Anything not listed is
  rejected with an `/ui/feedback` error before Ash is ever called. Destroy,
  update and generic actions are supported; a generic action with a
  `:record_id` argument receives the context's `"recordId"`.

  **Update actions via `invoke` call the named action itself** with no
  params on the identified record — an argument-less "touch-style" update.
  Actions that need user input declare `prompt_fields` on their `action`
  entity: then (and only then) the invoke context's `"values"` map is
  filtered to the declared prompt fields, cast against the Ash action's
  arguments/accepts, and passed as params (`"values"` on prompt-less actions
  is ignored). Don't put an update action in `row_actions` expecting it to
  receive *form* values — it won't; form input belongs to `update_action`.

  If the action's entity declares `visible_when` conditions, the handler
  fetches the identified record and re-evaluates them on **every** invoke —
  a non-visible action is rejected with an `/ui/feedback` error no matter
  what the client rendered. Never rely on the rendering to hide a button; the
  handler enforcement is the guarantee.
- `"prompt"` — context `%{"action" => name, "recordId" => id}`. Sent by the
  trigger of a prompt Modal (an action with `prompt_fields`). No Ash write:
  the handler validates the allowlist + `visible_when`, pre-fills
  `/prompt/values/<action>` from the record, and clears `/errors`. The
  actual write is the subsequent `"invoke"` with `"values"`.
- `"query"` — context `%{"query" => <the query state map>}` plus optional
  `"page"`/`"pageDelta"`. Requires the table to declare a `query` entity;
  every search/sort/filter/page value is validated against that allowlist
  and rejected with an `/ui/feedback` error when undeclared. Returns `updateDataModel`
  messages for `/records` and `/query`. On multi-table surfaces the context
  **requires** `"component" => table_name` and the messages target
  `/records/<name>` + `/query/<name>`. Full rules in `ash_a2ui:queries`.

## Reserved data-model paths

All follow-up messages are `updateDataModel` messages on these paths —
never invent ad-hoc paths or custom message types; renderers depend on
them:

- `/records` — the re-read table rows after a successful write (each row
  includes `"id"`, and reads exactly like the initial render's rows — enum
  labels, links, badges). Multi-table surfaces scope refreshes per table at
  `/records/<component_name>`.
- `/form` — the edit buffer: cleared to `%{}` on success and on
  `start_create`/`cancel_record_task`; populated by `start_edit`.
- `/errors/<field>` — per-field validation error text; `/errors` is cleared
  to `%{}` on success.
- `/ui/feedback` — the typed outcome of **every** action:
  `%{"kind" => "success" | "warning" | "error", "message" => text}`
  (success text, validation summary, rejection reason, "not authorized").
  The status Text binds `/ui/feedback/message`; the admin statusBanner binds
  both keys. On v1.0 surfaces the same outcome is also the structured
  `/ui/response` object and the `actionResponse` handshake.
- `/ui/intent` and `/ui/panel/*` — the task panel's state (`visible`,
  `mode`, `title`, `primary_label`, `record_id`, the `submit_visible` /
  `form_visible` / `view_visible` sentinels, and `record` — the read-only
  display values of a `view_record`).
- `/ui/action_result` — the map result of a map-returning generic action
  (an AshA2ui handler convention, not part of the A2UI spec).
- `/query` — the authoritative query state on query-enabled surfaces,
  written after `query` actions and query-aware success refreshes
  (multi-table surfaces: `/query/<component_name>` per query-attached
  table).
- `/prompt/values/<action>` — a prompt Modal's input values: pre-filled by
  `prompt`, cleared to `%{}` after a successful prompt `invoke`.
- `/prompt/select/<action>/<field>` — a searchable relationship prompt
  field's `{"search", "label"}` state.
- `/bulk/<table>/result` — the last bulk run's outcome (`ok`, `failed`,
  `refused`, `skipped`, `errors`); rows of bulk tables carry `_selected`.

On `Ash.Error.Forbidden` only an `/ui/feedback` "not authorized" error is
emitted — no field errors, to avoid leaking policy details. Errors without a
field put their own message in `/ui/feedback`; field errors stay on
`/errors/<field>`, and those on fields the action shows no input for (an
invoke's non-prompt fields, a form's fields without an input) are also named
in the feedback ("Status: must equal :claimed."). Return a plain string or
an Invalid-class `Ash.Error` with a readable message from a `via` function
or a custom change — that text is what the user reads. Any other error (a
raw exception such as `RuntimeError`, a data-layer error, a Framework-class
error) can carry row values, so it reads only "The action failed." and its
text goes to `Logger.error/1`.

## Scoping refreshes with `action` entities

By default every success refreshes **every** table. On multi-section
surfaces, declare which tables an action's success rewrites:

```elixir
action :approve do
  refreshes [:new_items]    # only /records/new_items (+ /query/new_items)
end
```

Use it when a row action logically belongs to one section — refreshing
unrelated tables wastes reads and can visibly reset their pagination. The
`/form`/`/errors`/`/ui/*` follow-ups are never affected. Refresh targets and
action reachability are compile-time verified. `refreshes` may be omitted
when the entity only carries `prompt_fields`/`visible_when` — omitted means
"refresh every table" (the default).

## Prompts and conditional visibility on `action` entities

```elixir
action :decline do
  label "Decline"                           # optional button text (row, bulk, prompt)
  prompt_fields [:notes]                    # args/accepts of :decline, compile-verified
  prompt_title "Decline referral"           # optional Modal heading (default: the label)
  visible_when status: [:pending, :approved]
end
```

- `label` is the text of the action's row, bulk and admin buttons, its
  prompt heading, its bulk status line and its success status ("Confirm
  match: done."; without a label, `Action "confirm_merge" completed.`). Use it instead of a thin
  wrapper action that exists only to rename a button.
- `prompt_fields` renders the row action as a Modal (trigger button +
  inputs + Confirm; under the admin catalog, a dialog the dataGrid opens
  from the entry's `prompt`) and freezes the `prompt`/`invoke "values"`
  wire contract above. Keep prompts to the action's real arguments — the
  handler filters everything else out anyway.
- Prompt inputs are typed like form inputs: a `belongs_to` source
  attribute (or a `field` with `relationship`) is a ChoicePicker over the
  actor's options (`/options/<field>`), or the searchable-select composite
  when the `field` declares `option_search` (its `option_select` carries
  `"prompt"` and writes `/prompt/values/<action>/<field>`); an enumerated
  argument is a ChoicePicker; booleans and dates get CheckBox and
  DateTimeInput. The server still casts and validates the values, and
  re-reads a relationship prompt value as the actor before the write: a
  value the picker would not have offered (a spoofed or stale id) fails on
  `/errors/<field>` ("is not one of the available options"). Form
  relationship selects are not re-checked on submit — there, as for any
  write, the resource's own validations and policies decide which related
  ids are allowed.
- `visible_when` is simple ANDed equality on public attributes or
  expression calculations (`nil` = is_nil, list = membership) —
  deliberately not a rules engine. Rendering hides the button per row in
  both compositions (server-computed `"_actions"` / `"_visible_<action>"`
  row keys; the admin `rowActions` entry names it as `visiblePath`) + a
  templated slot); the handler enforcement is mandatory and independent.
  Real authorization still belongs in Ash policies — `visible_when` is UX
  scoping inside the `row_actions` allowlist.

## Bulk actions

```elixir
component :table do
  row_actions [:approve]
  bulk_actions [:approve, :archive]   # update/destroy/generic, compile-verified
end
```

- `"bulk_invoke"` — context `%{"action" => name, "component" => table,
  "records" => <the carried rows>}` plus the usual `"query"`/`"contexts"`.
  The action must be in the surface's `bulk_actions` (and the table's own
  list) or it is refused before anything is read. Only the `"id"` of rows
  whose `"_selected"` is `true` is used; an empty selection is an error
  and more than one page (the query's `max_page_size`) is refused.
- The ids are **re-read** through the table's read under its active query
  preset (from the carried `"query"`, else `default_preset`: a
  `read_action` preset swaps the read, a `filter` preset ANDs on) with its
  context and section scope, as the actor. Ids the read does not return
  (forged, hidden by policy, out of scope or preset) count as `refused` and
  never reach the action. Each remaining record is checked against
  `visible_when` (`skipped` when it fails) and then runs through the same
  dispatch as `invoke`, one call per record, without a shared transaction.
- A **generic** bulk action must declare `argument :record_id` (compile-time
  verified): each call gets the record's id there.
- The handler writes `/bulk/<table>/result` and typed `/ui/feedback`
  (`"success"`, `"warning"` on partial success, `"error"` when nothing was
  written) and refreshes the targets once. Nothing is
  refreshed when nothing was written.
- `"bulk_select"` — context `%{"component", "selected" => true | false}`:
  the server re-reads the page and rewrites its rows with `_selected` set
  (Select page / Clear). Carried rows are never echoed back. On a table
  without a query, Select page marks at most the bulk cap's worth of rows.
- No `prompt_fields` on bulk actions, no bulk actions on related tables or
  `display :board` tables,
  and bulk actions are not exposed as AG-UI tools. Full contract in the
  bulk-actions topic.

## Rules

- Keep `row_actions` and `bulk_actions` minimal — they are allowlists, not
  documentation. Never mirror every action on the resource.
- Always pass `actor:` (and `tenant:` where relevant); `authorize?` defaults
  to `true` and should stay on.
- On a resource with **no policies**, `authorize?: true` is a no-op —
  transport-level authentication is the only gate. Say so in review rather
  than assuming enforcement.
- Values are serialized JSON-safe on the way out (dates/datetimes to
  ISO 8601, decimals to strings, atoms to strings) — don't re-serialize.
