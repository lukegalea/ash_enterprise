# Rules for queries and pagination

The `query` DSL entity is a **named, server-enforced allowlist** for search,
sorting, equality filters, and pagination. The core principle: **never accept
client sort/filter params not declared in a query.** The client references
the query by name (through the table component); the server validates every
requested sort/filter/search/page value against the declaration and rejects
anything else before Ash is called.

## Declaring

```elixir
a2ui do
  query :default do
    search_fields [:subject, [:requester, :email]]  # string attrs or rel paths, ci-contains, OR'd
    sortable [:subject, :inserted_at]
    filters [:status]                   # equality filters
    range_filters [:inserted_at]        # client-driven inclusive from/to bounds
    default_sort inserted_at: :desc
    page_size 25
    max_page_size 100
    default_preset :active

    preset :active do
      filter deleted_at: nil            # nil = is_nil; list = in; else equality
    end

    preset :deleted do
      read_action :deleted              # escape hatch for richer predicates
    end
  end

  component :table do
    fields [:subject, :status, :inserted_at]
    query :default
  end
end
```

- **`sortable` drives the admin grid's headers.** Under the admin catalog
  (1.7) every column whose field is in `sortable` gets a sort control in
  its header; a click sends the `query` action with the new sort and page 1,
  validated against the same allowlist.
- **Declare allowlists minimally.** Only add fields to `sortable`/`filters`/
  `search_fields` that the surface actually needs — every entry is
  client-reachable. Never mirror all public attributes "because they exist".
- All query fields must be public attributes; `search_fields` must be
  string-typed — a `search_fields` entry may also be a **relationship path**
  to a public string attribute (`[:requester, :email]`; to-many paths match
  when *any* related record matches). `sortable`/`default_sort` may
  additionally name public aggregates and expression-based calculations, and
  `filters` may name expression-based calculations (module-based
  calculations have no data-layer expression and are rejected everywhere;
  aggregates are sort-only). All verified at compile
  time — fix the declaration, do not work around the verifier.
- **`hidden_filters` drops a filter's picker, not the filter.** List there
  the `filters` entries the page sets itself (links to
  `?q[filters][<name>]=...`): they still apply, the controls just draw no
  picker for them. Each must also be in `filters`.
- **`range_filters` is the only client-driven bound mechanism.** Each
  declared field (public attributes only) gets `/query/ranges/<field>/from`
  and `/to` string bindings, cast to the attribute's type and ANDed as
  inclusive `>=`/`<=`; `""` means inactive. Plain `YYYY-MM-DD` bounds on
  datetime fields expand to the day's start/end, so a same-day from/to
  covers the whole day. Non-allowlisted fields and uncastable bounds are
  rejected before any read. (A `display :calendar` table's window is not a
  range filter: the client sends a date, never bounds, and the server
  derives the range. See `ash_a2ui:layout`.)
- **Presets are the composite-filter mechanism.** The client selects a
  preset **by name** (`"preset"` in the query state; a `ChoicePicker` is
  emitted) — predicates never travel over the wire. Use a keyword `filter`
  for AND-of-equality/is_nil/membership; use `read_action` for anything
  richer (`not is_nil`, ranges, ORs). `default_preset` applies when the
  client selects none *and* closes the set (no `""`/"All" escape to the
  unscoped base read); without it, `""` means "no preset". Presets are UX
  scoping — authorization stays in Ash policies. `preset_picker false`
  leaves the picker out when the page selects presets itself (tabs linking
  to `?q[preset]=...`); the presets still apply.
- `apply_on_change true` applies the query as its controls change (search
  after a 300 ms pause) instead of on Apply. The Apply button stays in the
  tree; renderers that honour the `/query` state's `autoApply` hide it.
  A query with nothing to pick (sort and page size only) gets no controls
  card either way.
- **Filter bar options (admin catalog 1.10).** All opt-in; a query
  without them emits exactly what it did.
  - `multi_select_filters [:status]` — a picker of several values
    (`multipleSelection`, no "All"); `/query/filters/<name>` is a list
    (`[]` = inactive) applied with `in`.
  - `filter_groups status: [expiring: [:expiring_soon, :renewal_scheduled]]`
    (+ `group_labels status: [expiring: "Expiring soon"]`) — nested
    options. A group is UI only: the filter only ever receives leaf values,
    so a link selecting a group lists its leaves
    (`?q[filters][status][]=expiring_soon&...`). Leaves must be declared
    choices, each in one group, and a group value is never also a leaf.
  - `facet_counts true` (or a list) — per-option counts at
    `/query/facets/<name>/<value>`, counted with search, ranges, the
    preset, the context scope and every *other* filter, under the actor's
    policies. One aggregate call per faceted filter (a filtered count per
    option); keep option lists short.
  - `filter_hints status: "..."` and `filter_labels vendor: "Vendor"` —
    the picker's footer hint and label (the label defaults to the field's
    declared `label`, then the humanized name).
  - `path_filters property: [:lines, :property, :name], vendor: :vendor_name`
    — filters over a related value: a relationship path (any related value
    matches) or one attribute/aggregate/expression calculation. Use a
    filtered aggregate when the path alone would match the wrong related
    records (a vendor party, not the PMC). Options are the distinct values
    of the read the actor can see, at `/query/options/<name>`. Values cast
    to the terminal field's type. Admin catalog only.
  - `search_placeholder "..."`, `controls_card false` (the bare Row under
    the same `query<sfx>_controls` id) and `page_size_options [10, 20, 50]`
    (each `<= max_page_size`; a size change starts at page 1).
  - `empty_state`, `no_results_state` (with `clear_action`) and a preset's
    `empty_state` — the admin grid's empty states; the runner writes the
    one that applies to `/query/emptyState`. The variants need the query's
    own `empty_state`.
  - `search_fields` may name a string aggregate (`:vendor_name`) — searched
    in the data layer like an attribute.
  Under the basic catalog groups flatten to their leaves, and hints,
  counts, placeholders and path-filter pickers are left out (the basic
  schemas are strict).
- On multi-table surfaces each named table may attach its own query; state
  lives at `/query/<component_name>` and the `query` action context requires
  `"component"` (the emitted controls send it automatically).
- Set `max_page_size` deliberately: it is the hard clamp on client-requested
  page sizes.

## Handling

- The `"query"` client action (context `{"query" => <the /query map>}` plus
  optional `"page"`/`"pageDelta"`) is handled by `AshA2ui.ActionHandler` like
  every other action — don't bypass it, and don't build your own filter/sort
  plumbing from client input next to it.
- Non-allowlisted requests come back as `{:error, [message]}` with the
  explanation as an `/ui/feedback` error and **no read executed**. Don't "fix" this by
  widening the allowlist reflexively; ask whether the field should really be
  client-sortable/filterable.
- Success refreshes of `submit_form`/`invoke` respect the carried `/query`
  state automatically (the encoder adds the binding). Don't strip the
  `"query"` key from contexts in custom transports if you want users to keep
  their page/filters after a write.
- PubSub refreshes through `AshA2ui.LiveRenderer` also preserve the user's
  current query: the renderer tracks the last `/query` state it pushed and
  passes it to `AshA2ui.Info.build_data_model/2` as `:query_state`. Custom
  transports driving `build_data_model/2` directly should pass their own
  `:query_state` if they want the same behavior.
- Pagination is limit/offset with a `page_size + 1` look-ahead for `hasMore`;
  resources do **not** need Ash `pagination` enabled on their read actions.
  `totalCount` may be `null` on data layers that cannot count — handle that
  in renderers.

## Avoid list

- ❌ Passing raw client sort/filter/search parameters into `Ash.Query`
  yourself — that is exactly what the query allowlist exists to prevent.
- ❌ Widening `sortable`/`filters` to every public attribute.
- ❌ Inventing a second query mechanism (custom action names, ad-hoc context
  keys) instead of declaring a `query` entity.
- ❌ Expecting fuzzy/custom *client-driven* predicates — filters are
  equality-only and client-driven bounds go through `range_filters`.
  Composite/rich predicates belong in a named `preset` (or a preset
  `read_action`), selected by name.
- ❌ Accepting client-sent predicates for presets — the wire carries only
  the preset **name**.
