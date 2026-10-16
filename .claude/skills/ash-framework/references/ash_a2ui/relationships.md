# Rules for relationship rendering

AshA2ui renders `belongs_to` **form selects** (ChoicePicker with options
loaded from the destination; searchable via `option_search`), **nested
relationship forms** (the `nested_form` entity over `manage_relationship`
actions), and **table columns read through loaded relationships** (the
`source` field option). All are server-resolved; the client only ever sees
plain option lists and plain values.

## Form selects for belongs_to

- **Rely on inference for the common case.** A form field whose name matches
  a `belongs_to` relationship's `source_attribute` (e.g. `:payment_group_id`
  for `belongs_to :payment_group`) renders as a ChoicePicker automatically —
  no `field` block needed:

```elixir
component :form do
  fields [:name, :payment_group_id]   # payment_group_id -> ChoicePicker
  create_action :create
end
```

- Use the `field` options only when the defaults are wrong:

```elixir
field :payment_group_id do
  relationship :payment_group   # explicit override (action-argument fields)
  option_label :name            # default: first of [:name, :title, :label, :username, :email], else PK
  option_value :id              # default: destination PK (composite PK requires explicit)
  option_sort :name             # default: the resolved option_label, ascending
  option_limit 100              # default: 100
end
```

- `relationship`, `option_label`, `option_value`, and `option_sort` are
  verified at compile time (real relationship; public destination
  attributes). A composite destination primary key without an explicit
  `option_value` is a compile-time error — fix the declaration.
- **Options are loaded through the destination's primary read action with
  the surface's `actor:`/`tenant:`/`authorize?:` opts** — destination
  policies apply. If option lists come back empty, check the destination's
  policies before anything else.
- Options land inline in the ChoicePicker *and* at the reserved
  `/options/<field>` data-model path (`[{"label": _, "value": _}]`, all
  strings). Code against `/options/<field>`; the inline copy exists because
  the v0.9.1 basic-catalog ChoicePicker can't bind dynamic options.
- **Do not raise `option_limit` for large option sets — declare
  `option_search` instead.** Truncation at the limit is deliberate; don't
  ship a 5,000-option dropdown.
- Submitted values arrive as strings through `/form/<field>` and are cast by
  the normal Ash changeset; one-element string lists from single-select
  pickers are unwrapped automatically. Don't pre-cast in transport code.

## Searchable selects (`option_search`)

```elixir
field :author_id do
  option_search [:name, :email]   # public STRING attributes of the destination
end
```

- Non-empty `option_search` swaps the ChoicePicker for a composite: label
  Text (`/select/<field>/label`), search TextField
  (`/select/<field>/search`) + button (`"option_search"` action), and an
  option List over `/options/<field>` whose row buttons send
  `"option_select"` with the option's value.
- Entries must be public **string-typed** destination attributes
  (compile-time verified) — the search is a case-insensitive contains, OR'd
  across entries, clamped to `option_limit`.
- Selection is a **server round-trip on purpose** (`"option_select"`
  re-fetches the record with the surface's actor/tenant — spoofed ids are
  rejected). Don't write `/form/<field>` client-side from option data.
- Non-searchable selects are byte-for-byte unchanged — adding
  `option_search` is opt-in per field.

## Nested relationship forms (`nested_form`)

```elixir
component :form do
  fields [:subject]
  create_action :create
  update_action :update

  nested_form :notes do            # :notes = the ACTION ARGUMENT
    fields [:body, :rating]        # create_inline sub-form fields
  end

  nested_form :tags do
    option_search [:name]          # searchable pick_existing picker
  end
end
```

- The entity name is the **action argument** consumed by a
  `manage_relationship` change — required on every action the form submits
  (compile-time verified). Never declare a mode: it is inferred from the
  change's options (`type: :append_and_remove` → pick_existing;
  `type: :direct_control` → create_inline; update-only configs are a
  compile-time error). Fix the action, not the DSL, when the inferred mode
  is wrong.
- `/form/<argument>` is an array of row maps, always present (initially
  `[]`). Rows mutate **only** through the `"nested_add"` /
  `"nested_remove"` actions (server replaces the whole array) and
  create_inline row inputs. Don't splice the array client-side.
- Rows carry server-stamped `"_row"` identity keys and, after failed
  submits, `"_error_<field>"` mirrors — all underscore keys are stripped
  before the argument cast, `"id"` is kept (so on_match updates instead of
  recreates). Programmatic error paths are
  `/errors/<argument>/<index>/<field>`.
- Deferred (don't emulate): many_to_many join-resource fields, recursive
  nesting, picker pagination (searching replaces paging).

## Table columns through relationships (`source`)

```elixir
component :table do
  fields [:role, :user_email]
end

field :user_email do
  label "Email"
  source [:user, :email]       # every step but the last: public relationship;
end                             # last step: public attribute of the destination
```

- The field name (`:user_email`) is the column identity — the `/records` row
  key, the cell binding, and the label default. It does not need to exist as
  an attribute.
- Relationship loading (`Ash.Query.load`) happens automatically on every
  read path (initial render, action refreshes, query reads).
- Nil (or unloaded) relationships render as `""` — don't add nil-handling
  calculations for display purposes.
- **Source columns are table-only and not sortable/filterable.** Listing one
  in a `:form` component or in a query's `sortable`/`filters`/
  `search_fields` is a compile-time error. If you need to sort by a related
  value, that's the roadmap's relationship-sorted columns — don't fake it
  with a duplicated attribute.

## Reference links (`link` / `links`)

```elixir
field :owner_name do
  source [:owner, :display_name]   # a calculation terminal is fine
  link :owner                      # to-one: belongs_to / has_one
end

field :subject_id do
  link {:person, :subject_id}      # bare id / polymorphic: {surface_key, id_path}
end

field :participant_links do        # may be virtual (no such attribute)
  links :participants              # to-many: has_many / many_to_many
  link_label :name                 # optional; default fallback chain
end
```

- Rows (and `/detail/<context>`, `/ui/panel/record`) carry the reserved
  `"_links"` key: `%{"<field>" => %{"surface", "recordId", "label"[,
  "href"]} | [same]}`. A field with no link for that row is **absent** —
  render its plain value. Rows of link-free tables carry no `"_links"`.
- **Pruning is per actor and automatic**: relationship links come from
  the authorized relationship load (a target the actor cannot read is not
  loaded, so not linked); the host's `AshA2ui.LinkResolver`
  (`config :ash_a2ui, :link_resolver`) maps targets to surface keys and
  may veto (return `nil`). Never re-check readability in a renderer.
- Links are UX, not authorization — the opened surface enforces its own
  policies.
- `config :ash_a2ui, :open_surface_url, "/app/r/{surface}/{recordId}"`
  adds a server-built `"href"` to every link and is the default
  `AshA2ui.LiveRenderer` navigation target.
- Admin catalog: link columns carry `"link": {"path": "_links/<field>"}`,
  FieldDisplays `"link": {"path": ".../_links/<field>"}`; activation calls
  the catalog's `openSurface` function (`{surface, recordId, query}`).
- Basic catalog, with `link_buttons: true` (the LiveRenderer sets it when
  it has `:open_surface` / `:open_surface_url`; off, links stay plain
  Text): a to-one link (`link :rel` / `link {surface, id_path}`) in a
  table cell, card-row title/meta or detail value wraps its value Text
  (same id) in a borderless Button `<value id>_link` dispatching
  `"open_surface"` with `{"field", "surface": {"path":
  ".../_links/<field>/surface"}, "recordId": {"path": ...}}`. The handler
  accepts it only for that field's resolved surface (no follow-ups; the
  record id is not checked, the opened surface authorizes its read) and
  `AshA2ui.LiveRenderer` then navigates like `"a2ui:open_surface"`. Only
  fields the resolver resolves in this render get a Button; `links`
  (to-many) stay plain text. Row data is unchanged. Rows without a link
  for the field still get the Button (it sits in the row template); it is
  acknowledged and opens nothing.
- Verified at compile time: `link` → public to-one relationship, `links`
  → public to-many, single-attribute destination PK, `link_label` a
  public destination field, `{surface, id_path}` walks public
  relationships to a public attribute/calculation. `links` (and virtual
  link) fields are display-only — never in a `:form`.

## Avoid list

- ❌ Declaring `field ... relationship ...` when the field name already
  matches the `belongs_to` source attribute (the inference covers it).
- ❌ Raising `option_limit` past a UI-sensible dropdown size (use
  `option_search`).
- ❌ `option_search` on non-string or private destination attributes
  (verifier error; the search is a string contains).
- ❌ Writing `/form/<field>` or splicing `/form/<argument>` rows client-side
  instead of going through `option_select`/`nested_add`/`nested_remove`.
- ❌ Naming a `nested_form` after the relationship instead of the action
  argument, or declaring one without a `manage_relationship` change behind
  it.
- ❌ Binding renderers to the inline ChoicePicker options instead of
  `/options/<field>`.
- ❌ Source paths through private relationships or ending in private
  attributes (verifier error; make them public deliberately or don't render
  them).
- ❌ Working around "not sortable" verifier errors by duplicating related
  data onto the resource just for sorting.
- ❌ Building link URLs or re-checking link readability client-side —
  read `_links/<field>` (absent = no link) and hand activation to
  `openSurface` (admin) or the `"open_surface"` action (basic).
- ❌ Passing `link_buttons: true` from a host whose transport swallows an
  accepted `"open_surface"` action — the handler returns no messages; the
  transport must navigate (or hand the request to its own
  `open_surface`), or the Buttons do nothing.
- ❌ Linking through a `source` column's raw foreign key when a label
  exists — `link :relationship` labels itself from the cell (or
  `link_label`).
