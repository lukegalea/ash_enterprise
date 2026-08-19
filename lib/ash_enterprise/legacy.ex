defmodule AshEnterprise.Legacy do
  @moduledoc """
  The read model over the legacy estate.

  One resource so far — `AshEnterprise.Legacy.User`, mapped onto `legacy.users`
  through a compatibility view. It is an ordinary platform resource in every way
  that matters: same policies, same tenancy, same admin UI, same A2UI surface.
  That is the claim the strangler demonstration exists to test, and the place to
  read the argument is `docs/plans/ash-strangler-in-reference-app.md`.

  Distinct from `AshEnterprise.Legacy.Twins`, which holds the *twins* — the
  legacy relations declared verbatim as Ash resources so a mapping has columns
  to name. Twins are generated, never written, and are deliberately kept out of
  the application's own domains: they are the old schema, not part of the model.

  ## Not exposed over the public API

  No `json_api` or `graphql` block, on purpose. The legacy read model is
  reachable through the admin UI, the A2UI surface and MCP tools — all of which
  run through the same policies — but publishing a filterable API over a schema
  mid-migration would make the migration's intermediate states a compatibility
  commitment. It stops being an implementation detail the moment a client
  depends on it.
  """
  use Ash.Domain,
    otp_app: :ash_enterprise,
    extensions: [AshAdmin.Domain]

  resources do
    resource AshEnterprise.Legacy.User
  end
end
