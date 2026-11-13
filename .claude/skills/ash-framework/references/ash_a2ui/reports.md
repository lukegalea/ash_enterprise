# Reports and CSV export

Covers `:report` components (aggregate/report queries over generic Ash
actions) and `export` blocks (server-generated CSV via a
`callRendererFunction` calling `downloadFile`). Full topic: `reports-and-exports`.

## `:report` components

- Use a `:report` component when the section renders **computed rows**
  (group-bys, aggregates, cross-resource stats), not resource records —
  tables are for records.
- Declare a generic (`:action`-type) action returning `{:array, :map}` on
  the resource; the component references it:

  ```elixir
  component :report, :usage do
    action :usage_report              # required, must be a generic action
    params [:from, :to]               # defaults to all action arguments
    fields [:user, :visits, :minutes] # required — columns can't be inferred
  end
  ```

- `fields` is the **column allowlist**: each entry is a key of the returned
  row maps (atom or string keys both work), rendered in this order. Rows
  are trimmed to these fields on the wire.
- Params render as TextFields bound to `/report/<name>/params/<param>`;
  the Run button dispatches the `"report"` client action. Blank params are
  unset; non-blank values are cast against the action's arguments;
  non-allowlisted keys are dropped before the cast.
- `param_placeholders search: "Search suppliers"` gives a param's input a
  placeholder (admin catalog; the label stays as its accessible name). Keys
  must be among `params`.
- A `field` override may name a report param or row key
  (`field :from do label "From date" end`): its `label` reaches the param
  input, the cell caption, the export column and the CSV header. Only
  `label` applies to a report name, and the override is shared with the
  surface's tables and form, so one name carries one label.
- The action runs actor-scoped with the surface's `authorize?` — scope
  inside the action's `run` via `context.actor` where needed.
- Results land wholesale at `/report/<name>/rows`. The `/ui/feedback`
  written for the run (and the `agentFunctionResponse` answering an
  `ashAction` call) carries `"result": {"count": n}`.
- Reports cannot carry table/form options (`query`, `row_actions`,
  `read_action`, `sections`, `editable`, …) — compile-time verified.
- Multiple reports per surface are fine (name them:
  `component :report, :usage do ... end`); the Run buttons carry
  `"component"` so the handler targets the right one.

## `export` blocks (CSV)

- `export` goes on a `:table` or `:report` component. Delivery is a
  `callRendererFunction` calling the ash_a2ui catalog's `downloadFile`
  (`allowedCallers: agentOnly`), args
  `{"filename", "mimeType", "dataUrl"}` (or `"url"` for hosts that upload
  and sign). The shipped hook implements `downloadFile` as a built-in; the
  shipped extension catalog (`priv/a2ui/v1_0/catalogs/ash_a2ui/`) declares
  it for validating renderers.
- Table exports honor the current search/filters/preset and context scope
  but ignore pagination — they export the filtered set up to `limit`
  (default 10_000). Report exports re-run the action with the carried
  params.
- `column_select true` renders per-column checkboxes bound to
  `/export/<name>/columns/<column>` (all `true` initially); only checked
  columns are exported, in declared order. Use it when the legacy screen
  had column-selectable CSV.
- `columns` (default: the component's fields) must be a subset of the
  component's fields; `filename` defaults to `<component name>.csv`. On
  dynamic table sets each expanded section exports its own scoped rows and
  the filename gains the sanitized section label.
- CSV is RFC-4180 (`AshA2ui.Csv`), headers are the humanized (or declared)
  field labels.
