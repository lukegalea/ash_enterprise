defmodule AshEnterprise.Automation.Validations.FactsOnly do
  @moduledoc """
  Keeps an `AshEnterprise.Automation.Occurrence`'s `data` to small, flat facts.

  Refuses nesting, more than 8 keys, more than 1 KiB encoded, a non-scalar value, and any
  key that names a secret (`password`, `passwd`, `token`, `secret`, `credential`, `apikey`,
  `api_key`, `authorization`). The key check is a tripwire for a writer that forgets the
  rule, not a filter for hostile input: the writers are the platform's own.
  """
  use Ash.Resource.Validation

  @max_keys 8
  @max_bytes 1024
  @secret ~r/pass|token|secret|credential|api_?key|authorization/i

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :data) do
      nil -> :ok
      data when is_map(data) -> check(data)
      _ -> fail("must be a map")
    end
  end

  defp check(data) do
    cond do
      map_size(data) > @max_keys -> fail("holds more than #{@max_keys} keys")
      Enum.any?(data, fn {k, _} -> not is_binary(k) end) -> fail("keys must be strings")
      Enum.any?(data, fn {k, _} -> Regex.match?(@secret, k) end) -> fail("names a secret")
      Enum.any?(data, fn {_, v} -> not scalar?(v) end) -> fail("must be flat: scalar values only")
      byte_size(Jason.encode!(data)) > @max_bytes -> fail("is larger than #{@max_bytes} bytes")
      true -> :ok
    end
  end

  defp scalar?(v), do: is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v)

  defp fail(message), do: {:error, field: :data, message: message}
end
