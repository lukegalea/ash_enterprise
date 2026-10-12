defmodule AshEnterprise.Security.Validations.OperatorPrivilegeNeedsSystemActor do
  @moduledoc """
  Refuses a role grant of an operator-only privilege
  (`AshEnterprise.Security.Privilege.operator_only?/1`) unless a system actor
  makes it, or trusted server code that has turned authorization off
  (`authorize?: false`: never reachable from a request, an API or a tenant's
  admin UI, all of which act as an authorized human).

  A tenant's Administrator holds `write` on roles and role grants, so without
  this they could grant themselves `read` on raw landings or `write` on erasure
  scopes: untenanted resources, where a `:global` grant reaches every tenant's
  rows. The one legitimate path is the seeder's
  `AshEnterprise.Platform.Seeder.grant_platform_operator/1` (behind
  `mix ash_enterprise.platform.grant_operator`), which runs as the `seed`
  system actor.

  The privilege lookup is a query, which is fine here: this is a validation on
  a write, not a policy check.
  """

  use Ash.Resource.Validation

  require Ash.Query

  alias AshEnterprise.Security.Checks.SystemActor
  alias AshEnterprise.Security.Privilege

  @impl true
  def validate(changeset, _opts, context) do
    with privilege_id when not is_nil(privilege_id) <-
           Ash.Changeset.get_attribute(changeset, :privilege_id),
         {:ok, %{resource_name: resource_name, name: name}} <- fetch(privilege_id),
         true <- Privilege.operator_only?(resource_name),
         true <- context.authorize? != false,
         false <- SystemActor.match?(context.actor, nil, []) do
      {:error,
       Ash.Error.Changes.InvalidAttribute.exception(
         field: :privilege_id,
         message:
           "#{name} is reserved for the platform operator and can only be granted " <>
             "by `mix ash_enterprise.platform.grant_operator`"
       )}
    else
      _ -> :ok
    end
  end

  defp fetch(privilege_id) do
    Privilege
    |> Ash.Query.filter(id == ^privilege_id)
    |> Ash.Query.select([:id, :name, :resource_name])
    |> Ash.read_one(authorize?: false)
  end
end
