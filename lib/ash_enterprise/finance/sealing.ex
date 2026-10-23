defmodule AshEnterprise.Finance.Sealing do
  @moduledoc """
  How the finance store keeps everything it holds shreddable (ADR 0024).

  Every value the finance store writes — a raw sheet row, the mapped fields
  of a ledger event — is sealed under the erasure scope of the linked
  account it came through (`connection:<linked account id>`). The ledger is
  append-only and chained, so nothing can be deleted from it; sealing is what
  makes "shred the whole finance store" true anyway: destroy the scope's
  key and every row stays, every chain still verifies, and nothing readable
  is left.

  ## One key per step

  `open/1` resolves the scope's key once (`Keyring.live_key/1`), for one
  sync step, and derives two subkeys from it
  (`AshEnterprise.Erasure.Crypto.derive_key/2`):

    * the **digest** key — `digest/2`, a keyed digest of a row's content.
      The raw layer compares it to decide whether a row changed, because the
      sealed bytes differ on every seal (fresh IVs) and so cannot be
      compared;
    * the **row-key** key — `row_key/2`, the stable key of a sheet row that
      has no id of its own (a manual Tiller row). A plain hash of an
      account, a date, an amount and a description is a dictionary away
      from them and would outlive a shred in the ledger's subject ids; a
      keyed one is neither.

  Holding the key for the length of one step is safe: anything sealed with
  it after a shred raced the step is sealed under a destroyed key, and so is
  unreadable like everything else.

  ## Readers

  `unseal/2` opens with the step's key. A reader outside a step (the
  consumers in PROD-13/14) uses `open_sealed/1`, which goes through the
  keyring per value and reads a shredded value as `:shredded`.

  The struct holds key material: it never inspects, and it is never stored.
  """

  alias AshEnterprise.Erasure.{Crypto, Keyring, Scope}

  @derive {Inspect, only: [:scope_id]}
  @enforce_keys [:scope_id, :dek, :digest_key, :row_key_key]
  defstruct [:scope_id, :dek, :digest_key, :row_key_key]

  @type t :: %__MODULE__{
          scope_id: Ash.UUID.t(),
          dek: binary(),
          digest_key: binary(),
          row_key_key: binary()
        }

  @doc "The step's keys for a live scope; `{:error, :scope_shredded}` once it is not."
  @spec open(Scope.t()) :: {:ok, t()} | {:error, :scope_shredded | :scope_unavailable}
  def open(%Scope{id: scope_id}) do
    case Keyring.live_key(scope_id) do
      {:ok, dek} ->
        {:ok,
         %__MODULE__{
           scope_id: scope_id,
           dek: dek,
           digest_key: Crypto.derive_key(dek, "finance/content-digest/v1"),
           row_key_key: Crypto.derive_key(dek, "finance/row-key/v1")
         }}

      {:error, :shredded} ->
        {:error, :scope_shredded}

      {:error, _unknown} ->
        {:error, :scope_unavailable}
    end
  end

  @doc "Seal a JSON-encodable term; base64 of the sealed binary."
  @spec seal(t(), term()) :: String.t()
  def seal(%__MODULE__{} = keys, term) do
    term
    |> encode!()
    |> Crypto.seal(keys.scope_id, keys.dek)
    |> Base.encode64()
  end

  @doc "Open a value sealed by `seal/2` with the step's key."
  @spec unseal(t(), String.t()) :: {:ok, term()} | :error
  def unseal(%__MODULE__{} = keys, encoded) when is_binary(encoded) do
    with {:ok, sealed} <- Base.decode64(encoded),
         {:ok, plaintext} <- Crypto.open(sealed, keys.dek) do
      Jason.decode(plaintext)
    else
      _ -> :error
    end
  end

  @doc """
  Open a sealed value outside a step: `{:ok, term}` while its scope is live,
  `:shredded` once it is not. Raises on tampering or a lost key (see
  `AshEnterprise.Erasure.Keyring`).
  """
  @spec open_sealed(String.t()) :: {:ok, term()} | :shredded
  def open_sealed(encoded) when is_binary(encoded) do
    case encoded |> Base.decode64!() |> Keyring.open!() do
      {:ok, plaintext} -> {:ok, Jason.decode!(plaintext)}
      {:shredded, _marker} -> :shredded
    end
  end

  @doc "The keyed digest of a term's canonical encoding (see the moduledoc)."
  @spec digest(t(), term()) :: String.t()
  def digest(%__MODULE__{digest_key: key}, term), do: Crypto.keyed_digest(key, encode!(term))

  @doc "The keyed, stable key of a row from its identifying parts."
  @spec row_key(t(), [String.t()]) :: String.t()
  def row_key(%__MODULE__{row_key_key: key}, parts) when is_list(parts) do
    key
    |> Crypto.keyed_digest(Enum.join(parts, <<0>>))
    |> binary_part(0, 32)
  end

  @doc """
  The canonical JSON of a term: maps with their keys sorted, recursively, so
  equal content always encodes to equal bytes (a map's iteration order is
  not sorted past 32 keys). Decimals encode as strings.
  """
  @spec encode!(term()) :: binary()
  def encode!(term), do: term |> canonical() |> Jason.encode!()

  defp canonical(%Decimal{} = decimal), do: Decimal.to_string(decimal, :normal)
  defp canonical(%Date{} = date), do: Date.to_iso8601(date)
  defp canonical(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp canonical(%Money{amount: amount, currency: currency}),
    do: canonical(%{"amount" => amount, "currency" => to_string(currency)})

  defp canonical(%{__struct__: _} = struct),
    do: raise(ArgumentError, "cannot seal #{inspect(struct.__struct__)}")

  defp canonical(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonical(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value
end
