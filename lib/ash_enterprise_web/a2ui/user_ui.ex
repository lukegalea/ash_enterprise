defmodule AshEnterpriseWeb.A2ui.UserUI do
  @moduledoc """
  A2UI surface for users.

  ## Why this is a standalone module

  `AshA2ui.Standalone` with `for_resource` keeps the UI declaration *out* of
  `AshEnterprise.Accounts.User`. That is a deliberate architectural boundary,
  not a style preference:

    * `ash_a2ui` is tier 3 in `docs/manifesto/06-reversibility.md` — unpublished,
      SHA-pinned, pre-1.0. Inline `a2ui do ... end` blocks would make the domain
      layer depend on it, and removing it would mean editing every resource.
      Here, removing it is deleting this directory.
    * Resources generated from the CDM corpus stay regenerable, because the
      generator never has to preserve hand-written UI metadata.

  ## Server-enforced query surface

  The `query` block is an allowlist, not a hint. A model cannot sort by a column
  it should not know exists, filter on one that was never published, or ask for a
  page size that would exhaust the server — the DSL bounds all three before any
  input reaches the data layer.

  Note the fields chosen: no `hashed_password`, and nothing from the token store.
  Field selection here is a security decision as much as a design one.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Accounts.User
    surface_id "users"

    query :default do
      search_fields [:email]
      sortable [:email, :created_on]
      default_sort created_on: :desc
      page_size 25
    end

    component :table do
      # Only PUBLIC attributes may appear here -- the DSL verifies this at
      # compile time and lists the valid alternatives, which is how
      # `confirmed_at` (private) was caught rather than shipping as a blank
      # column. Field selection on a user surface is a security decision:
      # `hashed_password` is private for exactly this reason.
      fields [:email, :state_code, :created_on]
      read_action :read
      query :default
    end
  end
end
