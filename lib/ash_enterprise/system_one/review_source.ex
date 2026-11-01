defmodule AshEnterprise.SystemOne.ReviewSource do
  @moduledoc """
  What the verdicts surface needs from this application to show a person
  the text a model judged and the thresholds that banded it
  (`AshJudgments.Banding.ReviewSource`, registered under
  `config :ash_judgments, :review_source`).

  ## The judged text

  `open_state/2` re-reads the observations from the ledger
  (`AshEnterprise.SystemOne.Judgment`) **as the actor**, so the ledger's own
  read policy decides who sees the text, and opens each sealed
  `state_ciphertext` through the erasure keyring
  (`AshEnterprise.Erasure.Keyring.open!/1`). The keyring is the one code
  path to key material; this module never holds a key.

  - A value sealed under a live erasure scope opens to its text.
  - A value whose scope was shredded reads as no text: the erasure worked.
  - A value with no erasure header was not sealed by this application, so
    it reads as no text too.
  - Anything else the keyring refuses (a lost key, a wrong master key, an
    altered ciphertext) raises, as the keyring does everywhere: reporting
    those as "no text" would hide data loss.

  The text is sealed when the judgment is recorded
  (`AshEnterprise.SystemOne.JudgedState`): a string state as it is, any
  other state as its canonical JSON. An agent reply's state is
  `%{"reply" => text}` (`AshEnterprise.Quality.Projections.ReplyText`), so
  a judgment about a reply opens to the reply text, not to that JSON
  (`ReplyText.text_of_sealed/1`).

  ## The thresholds

  `band_table/2` returns the DMN text of the band-table version the banding
  recorded, by the `definition_id` in its `band_table` ref, never the
  version published now. A table the tenant forked is read in the tenant as
  the actor; a platform baseline through
  `AshEnterprise.Process.Resolver.load_platform_definition/2`, the named
  home of the cross-tenant read. A row whose version or content hash does
  not match the ref reads as unknown.
  """

  @behaviour AshJudgments.Banding.ReviewSource

  require Ash.Query

  alias AshEnterprise.Decisions.Definition
  alias AshEnterprise.Erasure.{Crypto, Keyring}
  alias AshEnterprise.Process.Resolver
  alias AshEnterprise.Quality
  alias AshEnterprise.Quality.Projections.ReplyText
  alias AshEnterprise.SystemOne.Judgment

  @impl true
  def open_state(observations, opts) do
    ids = observations |> Enum.map(& &1.id) |> Enum.uniq()

    if ids == [] or is_nil(opts[:actor]) do
      %{}
    else
      Judgment
      |> Ash.Query.filter(id in ^ids)
      |> Ash.read(read_opts(opts))
      |> case do
        {:ok, rows} -> Map.new(rows, &{&1.id, shown(&1, open(&1.state_ciphertext))})
        {:error, _forbidden_or_invalid} -> %{}
      end
    end
  end

  @impl true
  def band_table(%{band_table: %{} = ref}, opts) do
    with id when is_binary(id) <- ref["definition_id"],
         {:ok, definition} <- definition(id, opts),
         true <- recorded_version?(definition, ref) do
      {:ok, definition.xml}
    else
      _ -> :error
    end
  end

  def band_table(_banding, _opts), do: :error

  # What the person reads of an opened state: a reply's text, or the
  # state's text as it was sealed.
  defp shown(%{subject_type: type}, text) when is_binary(text) do
    if type == Quality.subject_type(), do: ReplyText.text_of_sealed(text), else: text
  end

  defp shown(_judgment, text), do: text

  defp open(nil), do: nil

  defp open(sealed) when is_binary(sealed) do
    case Crypto.scope_of(sealed) do
      {:ok, _scope_id} -> sealed |> Keyring.open!() |> text()
      :error -> nil
    end
  end

  defp text({:ok, plaintext}), do: if(String.valid?(plaintext), do: plaintext)
  defp text({:shredded, _marker}), do: nil

  # The tenant's own fork first, as the actor; otherwise the platform
  # baseline, through the resolver's cross-tenant read.
  defp definition(id, opts) do
    case Ash.get(Definition, id, Keyword.put(read_opts(opts), :not_found_error?, false)) do
      {:ok, %Definition{} = definition} -> {:ok, definition}
      _ -> Resolver.load_platform_definition(:decision, id)
    end
  end

  defp recorded_version?(definition, ref) do
    matches?(to_string(definition.version), ref["definition_version"]) and
      matches?(definition.content_hash, ref["content_hash"])
  end

  # A ref that does not name a field does not constrain it.
  defp matches?(_value, nil), do: true
  defp matches?(value, expected), do: value == to_string(expected)

  defp read_opts(opts), do: Keyword.take(opts, [:actor, :tenant, :authorize?, :context])
end
