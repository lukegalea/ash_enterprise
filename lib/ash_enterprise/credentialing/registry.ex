defmodule AshEnterprise.Credentialing.Registry do
  @moduledoc """
  The state behind the registry's in-process fake: what a clinic activates credentials with
  when no real registry is configured.

  The application reaches the registry through `AshEnterprise.Credentialing.RegistryApi`
  (declared operations over HTTP, ADR 0063). With no `CREDENTIAL_REGISTRY_URL` its transport
  talks to `AshEnterprise.Credentialing.Registry.FakeProvider`, a plug that serves the
  synthetic spec over this module's table. So this module is the fake's memory, and the
  tests' and the showcase's way to see what the "registry" accepted:

    * `activate/2` accepts every activation, records it and answers with a reference of its
      own. Each activation is a new entry with a new reference, so activating twice is two
      activations: the act is not idempotent.
    * `lookup/1` answers `:active` with the latest reference for a credential it holds an
      activation of. Its record lives in this node's memory (an ETS table this process
      owns, its reason to be a process) and does not outlive the node, so for a
      credential it holds nothing of it answers `:unknown`, never `:not_found`: absence
      here is not proof that the registry never accepted one.
    * `activations/1` says how many activations of a credential it accepted, which is how
      a test or the showcase shows that a reconciled activation was not sent twice.
    * `entries/1` and `find/1` list activations and find one by its reference, for the fake.

  When the table is not there (the process is down) `activate/2` answers
  `{:error, :unavailable}` and the fake answers 503.
  """

  use GenServer

  @table __MODULE__

  @type answer :: %{status: :active | :unknown, reference: String.t() | nil}
  @type entry :: %{id: String.t(), credential_reference: String.t() | nil}

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set])
    {:ok, %{}}
  end

  @doc """
  Activate a credential. `credential_reference` is what the registry's client sent for it
  (`nil` when the caller has none), echoed back when the activation is listed.
  """
  @spec activate(Ash.UUID.t(), String.t() | nil) :: {:ok, String.t()} | {:error, :unavailable}
  def activate(credential_id, credential_reference \\ nil) when is_binary(credential_id) do
    if available?() do
      count = :ets.update_counter(@table, credential_id, {2, 1}, {credential_id, 0, nil})

      if credential_reference,
        do: :ets.update_element(@table, credential_id, {3, credential_reference})

      {:ok, reference(credential_id, count)}
    else
      {:error, :unavailable}
    end
  end

  @doc "Ask the registry whether it activated a credential."
  @spec lookup(Ash.UUID.t()) :: {:ok, answer()} | {:error, :unavailable}
  def lookup(credential_id) when is_binary(credential_id) do
    cond do
      not available?() -> {:error, :unavailable}
      (count = activations(credential_id)) > 0 -> {:ok, active(credential_id, count)}
      true -> {:ok, %{status: :unknown, reference: nil}}
    end
  end

  @doc "How many activations of a credential the registry accepted."
  @spec activations(Ash.UUID.t()) :: non_neg_integer()
  def activations(credential_id) when is_binary(credential_id) do
    if available?(), do: :ets.lookup_element(@table, credential_id, 2, 0), else: 0
  end

  @doc "Every activation of a credential, oldest first."
  @spec entries(Ash.UUID.t()) :: [entry()]
  def entries(credential_id) when is_binary(credential_id) do
    case available?() && :ets.lookup(@table, credential_id) do
      [{^credential_id, count, credential_reference}] ->
        for n <- 1..count//1 do
          %{
            id: reference(credential_id, n),
            credential_reference: credential_reference
          }
        end

      _none ->
        []
    end
  end

  @doc "The activation the registry gave this reference, or `:error`."
  @spec find(String.t()) :: {:ok, entry()} | :error
  def find(reference) when is_binary(reference) do
    if available?() do
      @table
      |> :ets.tab2list()
      |> Enum.flat_map(fn {credential_id, _count, _reference} -> entries(credential_id) end)
      |> Enum.find(&(&1.id == reference))
      |> case do
        nil -> :error
        entry -> {:ok, entry}
      end
    else
      :error
    end
  end

  @doc "Whether the registry's table is up."
  @spec available?() :: boolean()
  def available?, do: :ets.whereis(@table) != :undefined

  defp active(credential_id, count),
    do: %{status: :active, reference: reference(credential_id, count)}

  defp reference(credential_id, count) do
    digest =
      :sha256
      |> :crypto.hash(credential_id)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "stub-registry:#{digest}-#{count}"
  end
end
