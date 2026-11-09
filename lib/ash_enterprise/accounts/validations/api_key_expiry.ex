defmodule AshEnterprise.Accounts.Validations.ApiKeyExpiry do
  @moduledoc """
  A key's `expires_at` must exist, lie in the future and not exceed
  `AshEnterprise.Accounts.ApiKey.max_lifetime_days/0`.
  """
  use Ash.Resource.Validation

  alias AshEnterprise.Accounts.ApiKey

  @impl true
  def validate(changeset, _opts, _context) do
    now = DateTime.utc_now()

    case Ash.Changeset.get_attribute(changeset, :expires_at) do
      %DateTime{} = expires_at ->
        limit = DateTime.add(now, ApiKey.max_lifetime_days() * 86_400, :second)

        cond do
          DateTime.compare(expires_at, now) != :gt ->
            {:error, field: :expires_at, message: "must be in the future"}

          DateTime.compare(expires_at, limit) == :gt ->
            {:error,
             field: :expires_at, message: "must be within #{ApiKey.max_lifetime_days()} days"}

          true ->
            :ok
        end

      _ ->
        {:error, field: :expires_at, message: "is required"}
    end
  end
end
