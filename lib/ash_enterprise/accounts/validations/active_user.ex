defmodule AshEnterprise.Accounts.Validations.ActiveUser do
  @moduledoc """
  Refuses an action on a user whose lifecycle is not `:active`.

  Guards the password reset, which writes to a user it was handed rather than
  finding one through a read.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_data(changeset, :lifecycle_status) do
      :active -> :ok
      _ -> {:error, message: "the account cannot be used", field: :reset_token}
    end
  end
end
