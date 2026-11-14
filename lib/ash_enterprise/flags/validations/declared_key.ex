defmodule AshEnterprise.Flags.Validations.DeclaredKey do
  @moduledoc """
  A flag row may only name a key this build declares
  (`AshEnterprise.Flags.Catalogue`): a row for a key no code checks would read as a
  rollout that is not happening.
  """

  use Ash.Resource.Validation

  alias AshEnterprise.Flags.Catalogue

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    key = Ash.Changeset.get_attribute(changeset, :key)

    if is_nil(key) or Catalogue.declared?(key) do
      :ok
    else
      {:error, field: :key, message: "is not a declared feature flag"}
    end
  end
end
