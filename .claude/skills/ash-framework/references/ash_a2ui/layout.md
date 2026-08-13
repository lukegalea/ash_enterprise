# AshA2ui layout rules

Rules for the `group` and `row_layout` layout entities (see the Layout topic
for the full contract).

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
  select button are unchanged — they move into the card header.
- The badge binds the computed `_badge_<field>` row key (display text), not
  the raw value: declare `badge_text` for boolean/enum values you want to
  read well; unmatched values humanize. The raw field value stays in the
  row for `select_row` and filters.
- Without a `row_layout`, rows stay flat cell Rows — both layouts are
  byte-identical to the pre-layout encoder when undeclared, so adding one
  never breaks existing renderers.

## Avoid

- ❌ Expecting a real grid/wrap — "columns" is server-side chunking into
  Rows of equal-weight Columns.
- ❌ Styling through the DSL — spacing, colors, and card chrome belong to
  the renderer/theme, not the payload.
- ❌ Duplicating a field across `title`/`badge`/`meta` or across groups.
