defmodule AshEnterprise.Finance.Validations.Currencies do
  @moduledoc """
  `account_currencies` maps Tiller account ids (non-empty strings) to ISO
  4217 codes the money type knows. Refuses anything else by field, without
  quoting the value.
  """

  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    with :ok <- check_default(Ash.Changeset.get_attribute(changeset, :default_currency)) do
      check_map(Ash.Changeset.get_attribute(changeset, :account_currencies))
    end
  end

  # The inputs are the whole check: nothing here reads the stored row.
  @impl true
  def atomic(changeset, opts, context), do: validate(changeset, opts, context)

  defp check_default(nil), do: :ok

  defp check_default(code) do
    if known?(code),
      do: :ok,
      else: {:error, field: :default_currency, message: "is not a known ISO 4217 currency"}
  end

  defp check_map(nil), do: :ok

  defp check_map(map) when is_map(map) do
    if Enum.all?(map, fn {account, code} ->
         is_binary(account) and account != "" and is_binary(code) and known?(code)
       end),
       do: :ok,
       else:
         {:error,
          field: :account_currencies,
          message: "must map Tiller account ids to known ISO 4217 currency codes"}
  end

  defp check_map(_other),
    do: {:error, field: :account_currencies, message: "must be a map"}

  defp known?(code) when is_binary(code) do
    String.match?(code, ~r/\A[A-Z]{3}\z/) and match?({:ok, _}, Money.validate_currency(code))
  end

  defp known?(_code), do: false
end
