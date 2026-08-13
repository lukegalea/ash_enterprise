# Rules for surface contexts and detail components

`context` entities model **selection-driven screens**: a named,
server-validated record selection (pick a user → pick one of *their*
practices → see that pair's visits → open one visit's detail) that scopes
tables, filters dependent option lists, and feeds `:detail` components.
Reach for contexts when a whole surface pivots on "which record is
selected"; keep using plain query `filters` when the user is merely
narrowing a list.

## Declaring

```elixir
a2ui do
  context :user do
    resource MyApp.Accounts.User      # any Ash resource, not just the surface's
    option_label :email
    option_search [:email, :name]     # string attrs, ci-contains — the picker's search
  end

  context :practice do
    resource MyApp.Practices.Practice
    option_label :name
    depends_on :user                              # must be declared earlier
    depends_on_path [:memberships, :user_id]      # rels… + terminal attribute
    auto_select_single true                       # sole option selects itself
  end

  context :visit do
    resource MyApp.Visits.Visit
    picker false                      # selected only via select_context
  end

  component :table do
    fields [:patient_name, :status]
    context_filter user_id: :user, practice_id: :practice
    require_context [:user]           # no selection → no read, empty table
    select_context :visit             # per-row "select" button → master/detail
  end

  component :detail, :visit_detail do
    context :visit                    # fields resolve against Visit, not the surface
    fields [:patient_name, :status, :note_text]
  end
end
```

- **Declaration order is dependency order**: `depends_on` may only name a
  context declared earlier (rules out cycles). `depends_on` and
  `depends_on_path` always come as a pair.
- `depends_on_path` steps are public relationships of the context's own
  resource, ending in a public attribute compared against the parent's
  selected value (to-many paths match when any related record matches).
- `require_context` entries must appear in the same table's
  `context_filter`; `select_context` must name a context over the table's
  own resource; `context_filter`/`require_context`/`select_context` are
  table-only and `context` is detail-only. All compile-time verified
  (`AshA2ui.Verifiers.VerifyContexts`) — fix declarations, don't work
  around the verifier.
- `:detail` fields default to the **context resource's** public attributes
  and may include its public calculations/aggregates.

## Semantics to rely on (and not subvert)

- **Selection is server-authoritative.** The client only ever sends a
  record id; the changed context's id round-trips through an **authorized
  read** (actor/tenant/authorize? plus the dependency filter), so an id the
  actor can't read — or outside the selected parent's scope — is rejected.
  Never trust or persist the carried `label`.
- **Carried context values are UX scoping, not a security boundary** —
  exactly like query filters. Table reads scoped by `context_filter` run
  with the surface's actor as usual; authorization stays in Ash policies.
- **Cascades are automatic.** Changing or clearing a context clears every
  dependent context transitively, re-derives their option lists, and
  re-selects singletons under `auto_select_single`. Don't re-implement
  cascade logic in transports.
- `require_context` means *no read executes* while unmet — use it for
  tables that are meaningless (or expensive) unscoped.
- Wire contract (frozen): actions `"context_search"` / `"context_select"`
  / `"context_clear"`; paths `/context/<name>` (`{"search","value","label"}`,
  the whole `/context` map rewritten per change), `/options/<context>`
  (shared `/options` namespace — names must not collide with searchable
  select fields or nested-form arguments), `/detail/<context>`. Action
  contexts on context-enabled surfaces additively carry
  `"contexts": {"path": "/context"}`.
- PubSub refreshes through `AshA2ui.LiveRenderer` preserve selections (the
  renderer tracks the last `/context` it pushed and passes it to
  `AshA2ui.Info.build_data_model/2` as `:context_state`). Custom
  transports driving `build_surface/2`/`build_data_model/2` should pass
  `:context_state` themselves.

## Avoid list

- ❌ Modeling a simple enum/status narrowing as a context — that's a query
  `filter`. Contexts are for record *selection* that scopes sections.
- ❌ Treating `context_filter` scoping as access control — policies gate
  reads, contexts only narrow them.
- ❌ Selecting contexts by anything but id (labels, search strings) or
  writing `/context` values client-side without a `context_select`
  round-trip — the server rewrites `/context` authoritatively.
- ❌ Reusing a context name for a searchable select field or nested-form
  argument (the `/options/<name>` namespace is shared; the verifier
  rejects it).
- ❌ Building "pick a record then act on it" flows out of `/select` +
  ad-hoc handlers when a `context` (+ `select_context`) expresses it
  declaratively.
