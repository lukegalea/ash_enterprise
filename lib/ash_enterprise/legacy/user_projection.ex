defmodule AshEnterprise.Legacy.UserProjection do
  @moduledoc """
  The one place a legacy user becomes a `AshEnterprise.Accounts.ProjectedUser`.

  Two paths write `projected_users`: the change ledger's drain
  (`AshEnterprise.Ledger.UserIngestion`) and the backfill
  (`AshEnterprise.Legacy.UserBackfill.project_row/1`). Both call `project/1`, so the mapping from
  the legacy application's five states onto the platform's two cannot differ between them.

  `project/1` upserts the row and then aligns `lifecycle_status` through the platform's own state
  machine: a legacy user in any state but `active` must not sit in `projected_users` as
  `:active`, and a user who comes back to `active` must not stay `:inactive`. The upsert alone
  does not touch `lifecycle_status`, so a path that stopped at the upsert would leave whatever the
  row held, and the value a row ended up with would depend on which path had written it last.
  """

  alias AshEnterprise.Accounts.ProjectedUser
  alias AshEnterprise.Legacy.Estate
  alias AshEnterprise.Platform.SystemActor

  @doc """
  Upserts one legacy user and aligns its lifecycle.

  `attrs` carries `:id`, `:legacy_id`, `:login`, `:email`, `:full_name` and `:legacy_state`.
  Returns the projected row as it stands after the alignment, or `{:error, reason}`. Does not
  rescue: the caller decides what a refused row means.

  `:context` (a map) is set on the upsert and on the transition, so a caller that carries
  provenance for the audit log (the drain's ledger envelope) has it on both writes. `:actor`
  attributes both writes and defaults to `SystemActor.projection/0`, which is what the backfill
  uses.
  """
  @spec project(map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def project(attrs, options \\ []) do
    opts = opts(Keyword.take(options, [:context, :actor]))

    with {:ok, projected} <- ProjectedUser.project(attrs, opts) do
      align_lifecycle(projected, attrs.legacy_state, opts)
    end
  end

  defp align_lifecycle(%{lifecycle_status: :active} = record, legacy_state, opts)
       when legacy_state not in ["active", nil],
       do: transition(record, :deactivate, opts)

  defp align_lifecycle(%{lifecycle_status: :inactive} = record, "active", opts),
    do: transition(record, :activate, opts)

  defp align_lifecycle(record, _legacy_state, _opts), do: {:ok, record}

  defp transition(record, action, opts) do
    record
    |> Ash.Changeset.for_update(action, %{}, opts)
    |> Ash.update()
  end

  # The actor is `SystemActor.projection/0` rather than a person, and the tenant is the legacy
  # estate's organization. See `ProjectedUser`'s moduledoc for why borrowing a human name here
  # would be a lie.
  defp opts(extra) do
    [actor: SystemActor.projection(), tenant: Estate.organization_id(), authorize?: false]
    |> Keyword.merge(extra)
  end
end
