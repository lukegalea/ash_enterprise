defmodule AshEnterprise.Finance.Changes.RequireOwnSheetAccount do
  @moduledoc """
  Refuses a Tiller sheet for a linked account that is not one of the actor's
  own *active* Google Sheets (`google-sheet`) linked accounts.

  The lookup is `LinkedAccount.for_operation`, the resolution the provider
  actions use, read as the actor in the actor's tenant, so naming somebody
  else's account (or a Gmail one) finds nothing. A change, not a policy
  check: it queries, and policy checks never do.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Integration.LinkedAccount
  alias AshEnterprise.Security.ActorContext

  @integration "google-sheet"

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      linked_account_id = Ash.Changeset.get_attribute(changeset, :linked_account_id)

      if own_active_sheet_account?(linked_account_id, context) do
        changeset
      else
        Ash.Changeset.add_error(changeset,
          field: :linked_account_id,
          message: "is not one of your active Google Sheets linked accounts"
        )
      end
    end)
  end

  defp own_active_sheet_account?(nil, _context), do: false

  defp own_active_sheet_account?(linked_account_id, context) do
    opts =
      context
      |> Ash.Context.to_opts()
      |> Keyword.put(:tenant, ActorContext.tenant(context.actor))

    case LinkedAccount.for_operation(@integration, linked_account_id, opts) do
      {:ok, [_account]} -> true
      _ -> false
    end
  end
end
