defmodule AshEnterprise.Security.Changes.DefaultScopingBusinessUnit do
  @moduledoc """
  Fills in `scoping_business_unit_id` from the user's own business unit when the
  caller did not specify one.

  Almost every role assignment is scoped to the user's own business unit, and
  requiring the caller to say so would make the common case noisy and the
  cross-unit case indistinguishable from a forgotten argument. Defaulting here
  keeps the column required in the database — so scope is never ambiguous — while
  letting callers omit it.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :scoping_business_unit_id) do
      nil -> Ash.Changeset.before_action(changeset, &apply_default/1)
      _ -> changeset
    end
  end

  defp apply_default(changeset) do
    user_id = Ash.Changeset.get_attribute(changeset, :user_id)

    with false <- is_nil(user_id),
         {:ok, %{owning_business_unit_id: bu_id}} when not is_nil(bu_id) <-
           fetch_user(changeset, user_id) do
      Ash.Changeset.force_change_attribute(changeset, :scoping_business_unit_id, bu_id)
    else
      _ ->
        # Leave it unset and let the `allow_nil? false` on the relationship
        # report it. Inventing a business unit here -- the root, say -- would
        # silently grant a wider scope than anybody asked for.
        changeset
    end
  end

  defp fetch_user(changeset, user_id) do
    AshEnterprise.Accounts.User
    |> Ash.Query.filter(id == ^user_id)
    |> Ash.Query.select([:id, :owning_business_unit_id])
    # Structural read to compute a default. The action's own policies govern
    # whether the caller may assign roles at all.
    |> Ash.read_one(authorize?: false, tenant: changeset.tenant)
  end
end
