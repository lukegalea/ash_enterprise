defmodule AshEnterprise.Execution.Preparations.RejectionDetails do
  @moduledoc """
  Reads a request's `rejection_details` back off its sealed column, on every read.

  Why a preparation and not `ash_cloak`'s decrypt calculation: the value is written by
  the request change itself (`AshAgent.Invocation.Changes.Request` refuses a request
  the pre-check rejected), with `Ash.Changeset.force_change_attribute/3` — which needs
  the attribute to exist, and `ash_cloak` removes a cloaked one. So the attribute stays
  plain, `SealUnderScope` seals its change into `encrypted_rejection_details`
  (`changes:`), and this hydration is what puts it back on the row a reader holds —
  including `Map.get/2` readers in `ash_agent` (`AshAgent.Run.Stepper` builds a
  rejected tool call's result from it), which no calculation would reach.

  The opening mirrors `ash_cloak`'s decrypt calculation exactly (base64, the
  `:__ash_cloak__` tag, `[:safe]` term decoding, no compressed terms): the sealed bytes
  are the same format, so the erasure round-trip tests cover both sides. A shredded
  scope reads as the `AshEnterprise.Erasure.Shredded` marker, as a cloaked field does.
  """

  use Ash.Resource.Preparation

  alias AshEnterprise.Erasure.Keyring

  # Sobelow reads `@sobelow_skip` from the source AST; persisting it keeps
  # `--warnings-as-errors` from calling the attribute unused.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.after_action(query, fn _query, rows ->
      {:ok, Enum.map(rows, &hydrated/1)}
    end)
  end

  # A read that selected other fields leaves the column not loaded: nothing to open.
  defp hydrated(%{encrypted_rejection_details: %Ash.NotLoaded{}} = row), do: row

  defp hydrated(%{encrypted_rejection_details: nil} = row), do: row

  defp hydrated(row) do
    case row.encrypted_rejection_details |> Base.decode64!() |> Keyring.open!() do
      {:ok, sealed} -> %{row | rejection_details: unsealed(sealed)}
      {:shredded, marker} -> %{row | rejection_details: marker}
    end
  end

  # Refuse the compressed external-term format outright: the seal side uses
  # `:erlang.term_to_binary/1` with no `:compressed`, so a legitimate payload never
  # begins with <<131, 80>>. Refusing it avoids a decompression bomb, which `:safe`
  # does not (binary_to_term inflates compressed terms regardless).
  # Skipped locally and by name: the binary is one this application sealed under the
  # row's erasure-scope key and `Keyring.open!/1` authenticated, never a caller's
  # input, and it is decoded `[:safe]` with compressed terms refused first.
  @sobelow_skip ["Misc.BinToTerm"]
  defp unsealed(binary) do
    if match?(<<131, 80, _rest::binary>>, binary),
      do: raise(ArgumentError, "refusing to decode a compressed term during decryption")

    case :erlang.binary_to_term(binary, [:safe]) do
      {:__ash_cloak__, dumped} -> undump(dumped)
      value -> value
    end
  end

  defp undump(dumped) do
    case Ash.Type.cast_from_embedded(Ash.Type.Map, dumped, []) do
      {:ok, value} ->
        value

      other ->
        raise ArgumentError,
              "cannot load sealed rejection details via cast_from_embedded/3: #{inspect(other)}"
    end
  end
end
