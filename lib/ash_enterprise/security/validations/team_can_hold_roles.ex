defmodule AshEnterprise.Security.Validations.TeamCanHoldRoles do
  @moduledoc """
  Rejects assigning a role to an access team.

  Access teams are defined by two restrictions — they cannot own records and
  cannot hold security roles — and those restrictions are the *reason* they are
  the cheap sharing mechanism: role resolution can skip them entirely.

  Allowing a role here would not fail loudly. It would work, and then every
  effective-role query would silently have to walk teams it was designed to
  ignore, on every request, for every user. That is a performance regression that
  surfaces a long way from its cause, so it is rejected at the point of
  assignment.
  """

  use Ash.Resource.Validation

  require Ash.Query

  @impl true
  def validate(changeset, _opts, _context) do
    team_id = Ash.Changeset.get_attribute(changeset, :team_id)

    case fetch_team(changeset, team_id) do
      {:ok, %{team_type: :access, name: name}} ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :team_id,
           message: """
           #{inspect(name)} is an access team, and access teams cannot hold \
           security roles. Share records with it instead, or convert the \
           membership to an owner team.\
           """
         )}

      _ ->
        # Unknown or missing team: the foreign key reports it. Reporting it here
        # too would surface two errors for one mistake.
        :ok
    end
  end

  defp fetch_team(_changeset, nil), do: :missing

  defp fetch_team(changeset, team_id) do
    AshEnterprise.Accounts.Team
    |> Ash.Query.filter(id == ^team_id)
    |> Ash.Query.select([:id, :name, :team_type])
    |> Ash.read_one(authorize?: false, tenant: changeset.tenant)
  end
end
