defmodule AshEnterprise.Credentialing.Registry do
  @moduledoc """
  The registry a clinic activates credentials with, and the one module that would speak
  to it (Iron Law #20).

  A stub: there is no registry to call. It stands in for one that keeps a record of the
  activations it accepted, so that a caller who lost the answer can ask afterwards:

    * `activate/1` accepts every activation, records it and answers with a reference of
      its own. Each activation is a new entry with a new reference, so activating twice
      is two activations: the act is not idempotent.
    * `lookup/1` answers `:active` with the latest reference for a credential it holds an
      activation of. Its record lives in this node's memory (an ETS table this process
      owns, its reason to be a process) and does not outlive the node, so for a
      credential it holds nothing of it answers `:unknown`, never `:not_found`: absence
      here is not proof that the registry never accepted one.
    * `activations/1` says how many activations of a credential it accepted, which is how
      a test or the showcase shows that a reconciled activation was not sent twice.

  When the table is not there (the process is down) both calls answer
  `{:error, %AshEnterprise.Credentialing.RegistryError{reason: :unavailable}}`.

  A connector to a real registry replaces this module.
  """

  use GenServer

  alias AshEnterprise.Credentialing.RegistryError

  @table __MODULE__

  @type answer :: %{status: :active | :unknown, reference: String.t() | nil}

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set])
    {:ok, %{}}
  end

  @doc "Ask the registry to activate a credential. Returns the registry's reference."
  @spec activate(Ash.UUID.t()) :: {:ok, String.t()} | {:error, RegistryError.t()}
  def activate(credential_id) when is_binary(credential_id) do
    if available?() do
      count = :ets.update_counter(@table, credential_id, {2, 1}, {credential_id, 0})
      {:ok, reference(credential_id, count)}
    else
      unavailable()
    end
  end

  @doc "Ask the registry whether it activated a credential."
  @spec lookup(Ash.UUID.t()) :: {:ok, answer()} | {:error, RegistryError.t()}
  def lookup(credential_id) when is_binary(credential_id) do
    cond do
      not available?() -> unavailable()
      (count = activations(credential_id)) > 0 -> {:ok, active(credential_id, count)}
      true -> {:ok, %{status: :unknown, reference: nil}}
    end
  end

  @doc "How many activations of a credential the registry accepted."
  @spec activations(Ash.UUID.t()) :: non_neg_integer()
  def activations(credential_id) when is_binary(credential_id) do
    if available?(), do: :ets.lookup_element(@table, credential_id, 2, 0), else: 0
  end

  defp active(credential_id, count),
    do: %{status: :active, reference: reference(credential_id, count)}

  defp available?, do: :ets.whereis(@table) != :undefined

  defp unavailable, do: {:error, RegistryError.exception(reason: :unavailable)}

  defp reference(credential_id, count) do
    digest =
      :sha256
      |> :crypto.hash(credential_id)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "stub-registry:#{digest}-#{count}"
  end
end
