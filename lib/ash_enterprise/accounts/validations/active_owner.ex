defmodule AshEnterprise.Accounts.Validations.ActiveOwner do
  @moduledoc """
  The user a record is being issued to must exist and be `:active`.
  """
  use Ash.Resource.Validation

  alias AshEnterprise.Accounts.User

  @impl true
  def validate(changeset, _opts, _context) do
    with user_id when is_binary(user_id) <- Ash.Changeset.get_attribute(changeset, :user_id),
         {:ok, %{lifecycle_status: :active}} <-
           Ash.get(User, user_id, authorize?: false, not_found_error?: false) do
      :ok
    else
      _ -> {:error, field: :user_id, message: "must be an active user"}
    end
  end
end
