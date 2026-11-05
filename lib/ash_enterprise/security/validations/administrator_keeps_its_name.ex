defmodule AshEnterprise.Security.Validations.AdministratorKeepsItsName do
  @moduledoc """
  Rejects renaming the tenant's Administrator role.

  Four-eyes approvals that name the Administrator role, and the sole-administrator
  rule (`AshEnterprise.Execution.Approval.sole_administrator?/3`), find the role by
  its name. Renaming it would let one administrator set the other aside without
  revoking anything: rename the role both hold, create a new "Administrator" and take
  it, and be its only holder.
  """

  use Ash.Resource.Validation

  @name "Administrator"

  @impl true
  def validate(changeset, _opts, _context) do
    if changeset.data.name == @name and Ash.Changeset.get_attribute(changeset, :name) != @name,
      do: {:error, error()},
      else: :ok
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    {:atomic, [:name], expr(name == ^@name and ^atomic_ref(:name) != ^@name),
     expr(
       error(^Ash.Error.Changes.InvalidAttribute, %{
         field: :name,
         value: ^atomic_ref(:name),
         message: ^message()
       })
     )}
  end

  defp error, do: Ash.Error.Changes.InvalidAttribute.exception(field: :name, message: message())

  defp message,
    do: "the Administrator role keeps its name: approvals that name the role find it by it"
end
