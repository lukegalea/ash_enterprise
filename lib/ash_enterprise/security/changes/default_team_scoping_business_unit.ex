defmodule AshEnterprise.Security.Changes.DefaultTeamScopingBusinessUnit do
  @moduledoc """
  Fills in `scoping_business_unit_id` from the team's own business unit when the
  caller omitted it. The team-role counterpart of
  `AshEnterprise.Security.Changes.DefaultScopingBusinessUnit`.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    # Applied directly, not in before_action -- required-attribute validation
    # runs first, so a default set in a hook arrives too late. See the
    # UserRole counterpart for the full explanation.
    case Ash.Changeset.get_attribute(changeset, :scoping_business_unit_id) do
      nil -> apply_default(changeset)
      _ -> changeset
    end
  end

  defp apply_default(changeset) do
    team_id = Ash.Changeset.get_attribute(changeset, :team_id)

    with false <- is_nil(team_id),
         {:ok, %{owning_business_unit_id: bu_id}} when not is_nil(bu_id) <-
           fetch_team(changeset, team_id) do
      Ash.Changeset.force_change_attribute(changeset, :scoping_business_unit_id, bu_id)
    else
      # Leave unset so `allow_nil? false` reports it. Guessing a unit here would
      # grant a wider scope than anyone requested.
      _ -> changeset
    end
  end

  defp fetch_team(changeset, team_id) do
    AshEnterprise.Accounts.Team
    |> Ash.Query.filter(id == ^team_id)
    |> Ash.Query.select([:id, :owning_business_unit_id])
    |> Ash.read_one(authorize?: false, tenant: changeset.tenant)
  end
end
