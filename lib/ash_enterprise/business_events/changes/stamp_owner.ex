defmodule AshEnterprise.BusinessEvents.Changes.StampOwner do
  @moduledoc """
  Fills a ledger row's ownership columns from its `context["owner"]`.

  The package's `record` action accepts a fixed set of inputs, none of them
  the platform's ownership columns, so the owner rides in the `context`
  map — which is a chained column, so the attribution is tamper-evident
  along with the fact. `AshEnterprise.BusinessEvents.Recorder` builds that
  map; this change copies it onto the row:

      %{"owner" => %{"user_id" => uuid, "business_unit_id" => uuid | nil},
        "organization_id" => uuid}

  A row without an owner is refused: an unowned row on an owner-only
  resource would be readable by nobody, which is a silent loss rather than
  a fact. So is a row whose `context["organization_id"]` is not the tenant
  it is being written in — the chained copy and the tenancy column must
  agree.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    context = Ash.Changeset.get_attribute(changeset, :context) || %{}

    with {:ok, owner_id, business_unit_id} <- owner(context),
         :ok <- same_tenant(context, changeset.to_tenant) do
      Ash.Changeset.force_change_attributes(changeset, %{
        owner_id: owner_id,
        owner_type: :user,
        owning_user_id: owner_id,
        owning_business_unit_id: business_unit_id
      })
    else
      {:error, message} -> Ash.Changeset.add_error(changeset, field: :context, message: message)
    end
  end

  defp owner(%{"owner" => %{"user_id" => owner_id} = owner}) when is_binary(owner_id),
    do: {:ok, owner_id, Map.get(owner, "business_unit_id")}

  defp owner(_context), do: {:error, "a business event needs context.owner.user_id"}

  defp same_tenant(%{"organization_id" => organization_id}, tenant)
       when is_binary(organization_id) and organization_id == tenant,
       do: :ok

  defp same_tenant(_context, _tenant),
    do: {:error, "context.organization_id must be the tenant the event is recorded in"}
end
