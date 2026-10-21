# AshA2ui layout rules

Rules for the `group`, `step` and `row_layout` layout entities, for boards
(`display :board`) and for calendars (`display :calendar`). See the Layout,
Wizard Steps, Multi-Section Surfaces and Calendars topics for the full
contracts.

## Form groups

- Group form fields into labeled sections with `group` entities inside
  `component :form`:

  ```elixir
  group :scheduling do
    label "Scheduling"     # defaults to the humanized group name
    columns 2              # defaults to 1
    fields [:trial_days, :expires_at]
  end
  ```

- Every grouped field must be one of the form's fields and may belong to at
  most one group (compile-verified). Groups re-arrange containers only —
  inputs, `/form` bindings, `/errors/<field>`, and submit semantics are
  identical to ungrouped forms.
- Ordering contract: ungrouped fields render in place; a group renders whole
  at the position of its first member in the form's field order. Order the
  form's `fields` list (or `field ... order`) accordingly — don't expect
  groups to render in group-declaration order.
- Don't reach for `columns 3+` casually: the basic catalog cannot wrap, so
  wide grids stay wide on narrow clients.

## Wizard steps

- Split a long form into pages with ordered `step` entities inside
  `component :form` (the vocabulary is borrowed from PyroManiac):

  ```elixir
  step :who do
    label "Who"              # defaults to the humanized step name
    fields [:name, :email]
  end

  step :what do
    fields [:role, :team]
  end

  step :confirm do
    review? true             # read-only summary of /form; last step only
  end
  ```

- Every form field belongs to exactly one step; at least two steps; unique
  names; `review?` only on the last step and without `fields`; no `group`
  or `nested_form` on a stepped form (all compile-verified).
- It is still one form over one Ash action. `wizard_next` builds the full
  changeset over the carried `/form` without submitting it and reports only
  errors on fields of the current and earlier steps; nothing is persisted
  until the last step's normal `submit_form`. A failed submit jumps back to
  the earliest step owning an erroring field.
- The server re-checks carried state: `/form` keys outside the form's fields
  are dropped (on `wizard_next` and on the final `submit_form` — one shared
  changeset path), the index is clamped, a non-integer index is refused.
  Don't rely on the client to keep the user on a step.
- The review step binds raw `/form` values (a searchable select shows its
  `/select/<field>/label`); choice fields show their stored value, not the
  option label.
- State lives at `/ui/wizard` (`index`, `steps`, `<step>_visible`, `nav`) —
  see the Data Model Conventions topic. Forms without steps are unchanged.
- The panel's primary label reads "Next" until the last step, then the
  usual "Create X" / "Save changes"; the submit button appears only on the
  last step.
- Use steps for linear, server-validated flows. Branching flows, uploads,
  and steps that wait on background jobs belong in a LiveView. Agent-composed
  (`AshA2ui.Dynamic`) specs have no step vocabulary; the importer rejects
  them visibly.

## Card-style table rows

- Give a table the record-card shape (title + status badge header, labeled
  metadata grid) with the singleton `row_layout` entity:

  ```elixir
  row_layout do
    title :name
    badge :is_active
    badge_text true: "Active", false: "Inactive"
    meta [:slug, :trial_days]   # defaults to fields minus title/badge
    columns 2
  end
  ```

- `title`/`badge`/`meta` must reference the table's fields, each at most
  once (compile-verified). Row actions, prompts, `visible_when`, and the
  View/Edit controls are unchanged — they move into the card header.
- The badge binds the computed `_badge_<field>` row key (display text), not
  the raw value: declare `badge_text` for boolean/enum values you want to
  read well; unmatched values humanize. The field's own row key reads as the
  table cell does (enum values as their labels, on the initial render and
  every refresh alike).
- Give the badge a semantic tone with `badge_tones` (matched like
  `badge_text`, e.g. `badge_tones true: :success, false: :neutral`). Tones
  are `:neutral`, `:info`, `:success`, `:warning`, `:danger` and `:accent`;
  unmatched values are `:neutral`. Rows carry the tone at
  `_badge_tone_<field>` and the admin dataGrid's badge column binds it as
  `tonePath`. Use tones for meaning (state), not decoration.
- Without a `row_layout`, rows stay flat cell Rows — both layouts are
  byte-identical to the pre-layout encoder when undeclared, so adding one
  never breaks existing renderers.

## Boards

- A board is a sectioned `:table` whose sections are the values of an
  attribute, laid out as lanes side by side. Declare it with `display :board`,
  a `row_layout` (lanes render cards) and a `sections` block **without** a
  `source`:

  ```elixir
  component :table, :board do
    display :board
    row_actions [:claim, :complete]

    row_layout do
      title :name
      badge :priority
    end

    sections do
      scope_by :status                      # Ash.Type.Enum or one_of
      values [:open, :claimed, :completed]  # optional subset + order
      labels open: "To do"                  # optional heading overrides
    end
  end

  action :claim do
    visible_when status: :open
    refreshes [:board]                      # template key = every lane
  end
  ```

- `scope_by` must have enumerable values (an `Ash.Type.Enum` type or a
  `one_of` constraint); `values` entries and `labels` keys must be among
  them; `label`/`value`/`sort`/`read_action` need a `source` and
  `values`/`labels` its absence; no value twice in `values`, no two values
  that sanitize to the same lane name (`:"in-progress"` / `:in_progress`)
  (all compile-verified).
- On a board, `limit` caps the number of **lanes**, not cards per lane, and
  may not be below the lane count. Set a lane's page size with the lane
  query's `page_size`.
- Moving a card = running a transition: a row action on the resource,
  gated by `visible_when` on the lane attribute, that refreshes the
  template key. There is no drag-and-drop; don't generate a generic
  "set status" action to fake one — the resource's own actions keep the
  state-machine rules.
- Each lane is an expanded table (`/records/<lane>`, `/query/<lane>`,
  `scope_by == value` ANDed onto every read, so a client filter cannot pull
  in another lane's records). Its heading total is the reserved
  `/_lane_total_<lane>` string, rewritten by action refreshes and `query`
  actions but not by a `scope: :records` push. Empty lanes stay on the
  board.
- Attach a `query` for per-lane pagination; lanes show query controls only
  when the query declares search, presets, filters or ranges.
- Lanes are a `Row` of lane Columns at `weight` 1: they share the board's
  width instead of sizing to their cards. The merged catalog scrolls them
  inside the board below `--a2ui-board-lane-min-width` (default 18rem) —
  theme that token rather than styling lane widths per host.
- `select_context :<context>` on a board puts the "Select <context>"
  control on every card (master/detail: the card fills the context's
  `:detail` components). Prefer it to deep-linking away from the board.
  List-mode sectioned tables still reject `select_context`.
- `display :list` (the default) keeps the stacked rendering, so source-less
  sections work without a board too.
- Split a board into **swimlanes** with `swimlanes_by` in the same
  `sections` block: a second enumerated attribute (not `scope_by`) whose
  values become rows across every lane, each on a tone-coloured band:

  ```elixir
  sections do
    scope_by :stage                         # the stage columns
    swimlanes_by :severity                  # the rows (Ash.Type.Enum or one_of)
    swimlane_values [:emergency, :urgent, :routine]   # optional subset + order
    swimlane_labels emergency: "Emergency"  # optional heading overrides
    swimlane_tones emergency: :danger, urgent: :warning, routine: :success
  end
  ```

  Every (swimlane, lane) cell is its own expanded table,
  `<key>_<lane>__<swimlane>` (`board_open__urgent`), with both filters
  ANDed onto every read; a client filter on either attribute cannot widen
  a cell. `refreshes [:board]` still covers every cell. Tones are the
  `badge_tones` vocabulary (`:neutral` when unlisted), served as data at
  `/_swimlane_tone_<key>__<swimlane>` and painted by the merged catalog
  from the `--a2ui-swimlane-<tone>-background` / `-color` tokens — theme
  those, don't style swimlanes per host. Totals: per cell
  `/_lane_total_<cell>`, per swimlane `/_swimlane_total_<key>__<swimlane>`,
  per stage `/_lane_total_<key>_<lane>`.
- Records whose swimlane value is nil (or not in `swimlane_values`) show in
  no swimlane, and are missing from the stage totals too. When a nil means
  something (not yet triaged), give the board a calculation that maps it to
  a value and swimlane by that.
- Each cell is two reads (page + count) on every render and every refresh
  of the board: 3 stages x 5 swimlanes is 30 reads per transition. `limit`
  caps the cells (default 50); narrow `values` / `swimlane_values` before
  raising it.
- `swimlanes_by` needs `display :board` and no `source`; its values, labels
  and tones keys must be enumerated values, tones must be from the
  vocabulary, `swimlane_values` may not be empty, no two swimlanes (or
  cells) may share a runtime name, no runtime name may extend another at
  an underscore (`:high` with `:high_total`), and no cell may take another
  table's key (compile-verified).

## Calendars

- A calendar is a queried `:table` shown as a month, week or day grid.
  Declare `display :calendar`, a `date_field` and a `query`; add an
  `end_date_field` for multi-day records and a `granularity` (`:month`
  default, `:week`, `:day`):

  ```elixir
  component :table, :schedule do
    fields [:title, :status, :starts_on, :ends_on]
    display :calendar
    date_field :starts_on
    end_date_field :ends_on
    granularity :month
    query :schedule
    row_actions [:confirm]
  end
  ```

- `date_field`/`end_date_field` must be public `:date` or datetime
  attributes of the table's resource; a calendar takes no `sections` and no
  `bulk_actions` (compile-verified).
- The window rides on the query: the read is the table's read (preset,
  context scope, filters, search, actor) ANDed with the window, and the
  state lives at `/query/<table>/window` (`anchor`, `from`, `to`,
  `selected`, `label`, `scopeLabel`, `marks`). Don't add a `range_filters`
  entry for the date field to fake a window.
- Moving the window and picking a day are `"query"` actions with `anchor`
  (an ISO date or `"today"`), `windowDelta` (an integer) or `date` (an ISO
  date, `""` clears). The server derives the range; the client never sends
  one. A picked day narrows the read; `marks` still cover the window.
- Size the query's `page_size` to a window's usual record count: one page
  is shown per window, with pagination when it holds more.
- Days are cut in `config :ash_a2ui, :calendar_time_zone` (an IANA name
  or an `{m, f, a}` returning one; `"Etc/UTC"` by default): which day is
  today, where a datetime field's day starts and ends, the marks and the
  `_calendar_when` times. A zone other than UTC needs
  `config :elixir, :time_zone_database`. Set it to the zone your people
  read their day in; don't shift datetimes in a calculation to fake it.
- For quick ranges ("today", "tomorrow", "the next two weeks") declare
  presets on the calendar's query with `calendar_anchor <days from today>`:
  switching to one moves the window there and clears the picked day;
  staying on it leaves the window where the user takes it. The preset's
  read still ANDs with the window.
- To let the user switch between a month and a week (or a day), declare
  `granularities [:month, :week]`; `granularity` is the one it opens on
  (default: the first). Don't declare two calendar tables over the same
  read to get two views.
- Rows carry `_calendar_start`, `_calendar_end` and `_calendar_when`.
- The basic composition is an agenda (window controls above the table's
  list); the admin catalog (1.3) emits a `calendarView` wrapping the
  table's `dataGrid`, so row actions, prompts and pagination work
  unchanged.

## Avoid

- ❌ Expecting a real grid/wrap — "columns" is server-side chunking into
  Rows of equal-weight Columns.
- ❌ Styling through the DSL — spacing, colors, and card chrome belong to
  the renderer/theme, not the payload.
- ❌ Duplicating a field across `title`/`badge`/`meta` or across groups.
- ❌ Hardcoding one `:table` per status value — use a source-less `sections`
  block, so the lanes follow the attribute's declared values.
- ❌ One board per severity (or per team) stacked on a page — use
  `swimlanes_by`, so the stages line up and one refresh covers every cell.
- ❌ Treating steps as a security boundary. They decide what is shown and
  when it is checked; the final submit validates every field, and
  authorization runs on that write.
