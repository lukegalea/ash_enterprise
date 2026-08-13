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
- **`range_filters` is the only client-driven bound mechanism.** Each
  declared field (public attributes only) gets `/query/ranges/<field>/from`
  and `/to` string bindings, cast to the attribute's type and ANDed as
  inclusive `>=`/`<=`; `""` means inactive. Plain `YYYY-MM-DD` bounds on
  datetime fields expand to the day's start/end, so a same-day from/to
  covers the whole day. Non-allowlisted fields and uncastable bounds are
  rejected before any read.
- **Presets are the composite-filter mechanism.** The client selects a
  preset **by name** (`"preset"` in the query state; a `ChoicePicker` is
  emitted) — predicates never travel over the wire. Use a keyword `filter`
  for AND-of-equality/is_nil/membership; use `read_action` for anything
  richer (`not is_nil`, ranges, ORs). `default_preset` applies when the
  client selects none *and* closes the set (no `""`/"All" escape to the
  unscoped base read); without it, `""` means "no preset". Presets are UX
  scoping — authorization stays in Ash policies.
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
  explanation on `/ui/status` and **no read executed**. Don't "fix" this by
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
