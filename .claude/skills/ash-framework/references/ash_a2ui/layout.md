# AshA2ui layout rules

Rules for the `group`, `step`, `row_layout` and `column` layout entities, for boards
(`display :board`), for calendars (`display :calendar`) and for timelines
and matrices (`display :timeline`, `display :matrix`). See the Layout,
Wizard Steps, Multi-Section Surfaces, Calendars and Timelines and Matrices
topics for the full contracts.

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
  are `:neutral`, `:info`, `:success`, `:warning`, `:danger`, `:accent`,
  `:pending` (gold: waiting on someone) and `:gray` (inactive, distinct from
  `:neutral`);
  unmatched values are `:neutral`. Rows carry the tone at
  `_badge_tone_<field>` and the admin dataGrid's badge column binds it as
  `tonePath`. Use tones for meaning (state), not decoration.
- Explain each badge value in one line with `badge_help` (matched like
  `badge_text`, e.g. `badge_help active: "Contract is currently active"`):
  the admin grid draws it as the pill's tooltip. Translated as display
  metadata; rows carry it at `_badge_help_<field>` (`""` unmatched) and the
  badge column binds it as `helpPath` (catalog 1.11).
- Without a `row_layout`, rows stay flat cell Rows — both layouts are
  byte-identical to the pre-layout encoder when undeclared, so adding one
  never breaks existing renderers.

## List rows (`display :rows`)

- A record page's related lines (an order's items and prices, its
  shipments) read as a stack of rows, not a grid: `display :rows` plus a
  `row_layout`. The layout's `trailing` fields sit at the row's end,
  right-aligned (an amount, a due date); its `expand` fields show only when
  the row is opened, and declaring any makes every row a disclosure:

  ```elixir
  component :table, :items do
    label "Items"
    resource MyApp.OrderItem
    display :rows
    fields [:product_name, :delivery_window, :price, :notes]
    context_filter order_id: :order

    row_layout do
      title :product_name
      trailing [:price]
      expand [:notes]
    end
  end
  ```

- `trailing`/`expand` must reference the table's fields (compile-verified)
  and drop out of the default `meta`. `display :rows` without a
  `row_layout` does not compile.
- Admin catalog 1.12: the dataGrid carries `"layout": "rows"` and those
  columns `"placement": "trailing" | "expand"`. A renderer that draws list
  rows uses them; one that ignores them draws the grid with every column.
  The basic card has no trailing slot or disclosure: both join its
  metadata grid.
- Lines that belong to something (an order's items per warehouse) group
  with `group_by`: each run of consecutive rows sharing its value is headed
  once, with `group_subtitle` under the header and `group_icon` beside it.
  Rows are grouped as they arrive, so sort the table's read (or its query)
  by the group first:

  ```elixir
  row_layout do
    group_by :warehouse_name
    group_subtitle :warehouse_address
    group_icon "home"
    title :product_name
    trailing [:price]
  end
  ```

- A row about a file reads as a document row: its type as a `leading` code
  before the title (`"PDF"`), and a trailing link that downloads it
  (`link_url :uri` plus `download true` on the field). Admin catalog 1.15:
  the column carries `"placement": "leading"`; the basic card keeps it in its
  metadata grid.
- A line under a table's rows, in the same card ("2 versions on file"), is a
  `footer_note :field` on the table (a field of its context record, read
  like a `section_note`), with an optional `footer_link href: "#history",
  label: "All versions"`. Admin catalog only: the dataGrid's `footerNote`
  and `footerLink`.
- `group_subtitle` and `group_icon` need a `group_by`; both fields must be
  the table's and drop out of the default `meta`. Admin catalog 1.14: their
  columns carry `"placement": "group" | "groupSubtitle"` and the dataGrid
  `groupIcon`; the basic card shows them in its metadata grid.

## Cards (`display :cards`)

- Records that each read as a small document (an order's notes, a policy's
  terms) draw one card per row: `display :cards` plus a `row_layout`. The
  layout's `title` and `badge` head the card, its `meta` fields are
  labeled rows, and its `expand` fields fold under a disclosure named by
  `expand_label`:

  ```elixir
  component :table, :terms do
    resource MyApp.OrderTerm
    display :cards
    fields [:name, :status_text, :details, :original_text]
    context_filter order_id: :order

    row_layout do
      title :name
      badge :status_text          # a string already in words shows as written
      meta [:details]
      expand [:original_text]
      expand_label "Show original text"
    end
  end

  field :details, do: pairs(true)
  ```

- A field's `pairs true` says its value is a list of
  `%{"term" => _, "value" => _}` maps (an `{:array, :map}` calculation):
  labeled values whose labels differ per record. The renderer draws one
  labeled row per pair.
- `display :cards` without a `row_layout`, and `expand_label` without
  `expand` fields, do not compile. `expand_label` translates as metadata.
- Admin catalog 1.16: the dataGrid carries `"layout": "cards"` and
  `expandLabel`, and the pairs column `"pairs": true`. A renderer that
  ignores them draws the grid. The basic catalog draws its usual card,
  with the expand fields in its metadata grid.

## Step fields (`steps true`)

- A detail value that is a sequence of stages (an order's fulfilment:
  Placed → Packed → Shipped → Delivered) draws as a numbered stepper: a
  field whose value is a list of step maps, declared `steps true`.

  ```elixir
  # on MyApp.Order: one map per step
  calculate :fulfilment, {:array, :map}, MyApp.Order.Fulfilment do
    public? true
  end

  # [%{label: "Placed",    text: "3 Nov 2026", state: :complete},
  #  %{label: "Packed",    text: "4 Nov 2026", state: :complete},
  #  %{label: "Shipped",   text: "Not yet",    state: :current,
  #    note: "Waiting for the carrier"},
  #  %{label: "Delivered", text: "Not yet",    state: :upcoming}]

  component :detail, :fulfilment do
    context :order
    fields [:fulfilment]
  end

  field :fulfilment do
    steps true
    empty_text "Not placed yet"
  end
  ```

- Each step: `label` (required), `text` (the line under the label: a date,
  "Not yet"), `note` (a smaller line) and `state`, one of `complete`,
  `current`, `upcoming` or `overdue`. Keys and the state may be atoms or
  strings. The step's place in the list is its number.
- Bad values never fail the page: a step without a label is left out (the
  rest are numbered 1..n), a missing or unknown state reads as `upcoming`,
  a blank `text` or `note` is left out, and a value that is not a list has
  no steps (the field's `empty_text` and the card's `hide_empty` apply).
  Return the label you want shown; do not rely on the fallbacks.
- The detail data carries the normalized steps at `_steps_<field>`: each
  `{number, label, text?, note?, state, stateLabel, line}`, where
  `stateLabel` is the state in words (a library string, translated) and
  `line` the whole step as one line ("3. Shipped · Current · Not yet ·
  Waiting for the carrier").
- Admin catalog 1.17: the `fieldDisplay` binds them as `steps`; the stock
  renderer draws an ordered list with each step's number, label, state (as
  words, not only colour), text and note, and marks the current step
  `aria-current="step"`. The basic catalog draws one Text row per step
  (its `line`), so a basic-only client still shows every step.
- Steps are drawn on `:detail` cards; a table or panel shows the raw value.
  `steps` with `pairs`, a badge (`badge_text`, `badge_tones`,
  `badge_help`), `link`, `links`, `link_url` or `source` does not compile.

## Table card headers (`heading`, `description`)

- A table that sits in a card of its own on a record page takes a card
  header and a one-line caption above its rows. Several tables can share
  one page `section` heading and each still name its own card:

  ```elixir
  component :table, :lines do
    section "Order"
    heading "Order lines"
    description "Each line on this order, newest first."
    resource MyApp.OrderLine
    fields [:product_name, :quantity, :price]
    context_filter order_id: :order
  end

  component :table, :shipments do
    section "Order"
    heading "Shipments"
    resource MyApp.Shipment
    fields [:carrier, :shipped_on]
    context_filter order_id: :order
  end
  ```

- `heading` is not `label`. `label` names the table's section (the
  heading over a table on multi-table surfaces) and the collection's
  accessible name; `heading` is drawn only where declared, inside the
  table's card. Use `heading` for the card's own header.
- Both are static text, translated in the metadata domain. For a line that
  reads from the record (a count, a date), use a `section_note` or a
  `footer_note` instead.
- Admin catalog 1.18: the dataGrid carries `heading` and `description`
  only when declared. The stock renderer draws the grid as one card, the
  header on top and the caption muted under it, in every layout (table,
  rows, cards) and above the empty state when there are no rows. The basic
  catalog draws a level-3 Markdown heading Text and a caption Text just
  before the table.
- Tables only, and not on a board (a lane has no card): elsewhere they do
  not compile.

## Table columns

- A `column` entity on a `:table` says how the admin data grid draws one
  field's cell beyond its value: `subtitle` (a second line), `icon` (a
  leading icon picked per row through `icon_names`, with `icon_tones` and
  `icon_labels`), `more` (a count field; 2 or more adds "+N more") and
  `detail` (a line under the value, its text per value in `detail_text`,
  `{date}` filled from `detail_date`, after an optional icon per value in
  `detail_icon_names` / `detail_icon_tones`):

  ```elixir
  column :title do
    subtitle :assignee_name
    icon :priority
    icon_names high: :alert, low: :check
    icon_tones high: :danger, low: :success
  end

  column :status do
    detail :status_detail
    detail_date :due_on
    detail_text overdue: "Overdue since {date}"
    detail_icon_names overdue: :alert
    detail_icon_tones overdue: :danger
  end
  ```

- Every field a column reads from must be a table field: rows carry it, and
  the grid draws it inside the column instead of as a column of its own. A
  field a column reads from cannot be a column itself.
- Icons come from a small generic vocabulary (`AshA2ui.Column.icons/0`:
  `:check`, `:x`, `:user_check`, `:user_x`, `:alert`, `:clock`, `:info`,
  `:refresh`, `:extend`);
  each renderer maps the names onto its own icons. Give every meaningful
  icon an `icon_labels` entry — it is the icon's accessible name.
- Rows carry the computed parts at reserved keys: `_icon_<column>`,
  `_icon_tone_<column>`, `_icon_label_<column>`, `_detail_<column>`, and
  with detail icons `_detail_icon_<column>` and `_detail_icon_tone_<column>`
  (`""` when the row's value has none). A detail icon is decorative: the
  line's text carries the meaning.
- Only the admin data grid draws these hints (catalog 1.8); a renderer that
  ignores them draws the plain value, and the basic composition keeps
  showing the folded fields as cells.
- Catalog 1.10 adds, all optional and admin-only:
  - `help_title` + `help` — header help behind an info mark; paragraphs
    split on blank lines, a line `**Term** — text` is a definition. The
    column carries `"help": {"title", "body"}`.
  - `detail_help :field` — a field explaining the detail line, drawn as an
    info mark with a tooltip; rows carry it at `_detail_help_<column>` and
    the column's `detail` at `helpPath`. Needs `detail`.
  - `sort_by :field` — the header sorts by another field (a module
    calculation shown, a stored copy sorted). It must be in the query's
    `sortable`; the column carries `"sortField"`.
  - `width 320` — a fixed width in px (`"width"`); `primary_action` takes
    `width` too (`rowClick.width`).
  - `more_values :field` (a `list` aggregate) and `more_noun "properties"`
    — every value behind "+N more", as strings at `_more_values_<column>`
    (`more.valuesPath`), and the noun for their caption (`"moreNoun"`).
    Needs `more`.
- Catalog 1.11 adds, all optional and admin-only:
  - `caption :field` + `caption_text "Created {date}"` — a third line under
    the value and its subtitle (a contract's created date under its vendor).
    `{date}` is the field's value formatted as a date in the reader's locale,
    `{value}` the value as is; without `caption_text` the line is the value.
    The field is folded like `subtitle`; the column carries
    `"caption": {"path", "text"}`. `caption_text` needs `caption`.
  - `sort_first :desc` — the header's first click sorts descending (a date
    read newest first). The column carries `"sortFirst": "desc"`.
  - On the badge column, `badge_help` (on the `row_layout`, see above).
- `column_order :fields` on a table with a `row_layout` orders the admin
  grid's columns as the component's `fields` (default `:layout`: title,
  badge, meta). The badge column keeps its `badge_text`/`badge_tones`
  wherever it lands.

## Primary action (admin dataGrid)

- `primary_action` on a `:table` draws the row click (the
  `select_context` selection, else View) as one button per row, in a final
  column. Use it when the list's last column reads differently per row but
  always opens the record ("Review", "Approve", "View"):

  ```elixir
  primary_action do
    label_from :next_step
    labels review: "Review", approve: "Approve"
    variants review: :primary, approve: :default
    variant :borderless
  end
  ```

- `label_from` is any public attribute, calculation or aggregate; it is
  loaded for the table without becoming a column. Values with no
  `labels`/`variants` entry get `label` (default: the row click's own
  label) and `variant` (default `:default`). Variants are the A2UI
  Button's: `:default`, `:primary`, `:borderless`.
- Rows carry `_primary_label` and `_primary_variant`; the grid's
  `rowClick` gains `labelPath`, `variantPath` and `inline: true`, and the
  row action the row click mirrors (View, or the `select_context` entry)
  leaves `rowActions`, so the row shows that action once. The
  button dispatches exactly what the row click does: never use it for an
  action that does something else (declare a row action with
  `visible_when` instead).
- The table needs a row click: a `select_context`, or a `:form` on the
  surface with the table over the surface's own resource (verified).

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

## Timelines and matrices

- A timeline is a `:table` read in time order: `display :timeline` and a
  `date_field` (a public date or datetime attribute). Without a declared or
  requested sort it reads oldest first. Rows carry `_timeline_at` and
  `_timeline_when` (both `""` with no value) and each basic row leads with a
  caption bound to `_timeline_when`. No `sections`.
- A matrix is a `:table` laid out as a grid: `display :matrix` with
  distinct `row_field`, `column_field` and `cell_field` attributes. The
  server serves the grid at `/_matrix_<table>`; a cell with no value is
  `"recorded": false` ("Not recorded"), never an empty value. An enumerated
  `column_field` keeps every declared value as a column. No `sections`,
  `row_layout`, `row_actions`, `bulk_actions` or `editable`. Give it a page
  size that holds the grid: it is built from the page read.
- Both render basic-catalog compositions under every catalog, so a client
  that only advertises the basic catalog shows them in full.

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
