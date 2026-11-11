defmodule AshEnterprise.Bpmn.Subscription.Validations.CausingPersonAllowlisted do
  @moduledoc """
  Refuses `:causing_person` on a subscription whose key is not the one the allowlist names.

  See `AshEnterprise.Bpmn.Subscription.Authority` for why the list exists and why it holds
  exactly one key.
  """

  use Ash.Resource.Validation

  alias AshEnterprise.Bpmn.Subscription.Authority

  @impl true
  def validate(changeset, _opts, _context) do
    key = Ash.Changeset.get_attribute(changeset, :key)

    if Ash.Changeset.get_attribute(changeset, :authority) == :causing_person and
         not Authority.causing_person?(key) do
      {:error,
       field: :authority,
       message:
         "#{inspect(key)} may not run as the causing person: only the one reviewed key in " <>
           "the causing_person_keys allowlist may"}
    else
      :ok
    end
  end
end
