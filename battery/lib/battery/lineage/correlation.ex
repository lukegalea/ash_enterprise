defmodule Battery.Lineage.Correlation do
  @moduledoc """
  The battery's `AshOpenLineage.CorrelationProvider`: one correlation id per process, minted
  on first use and kept in the process dictionary, depth zero. The scenarios drive their
  work in the test process, so every event of one scenario step shares one id.
  """

  @behaviour AshOpenLineage.CorrelationProvider

  @key {__MODULE__, :id}

  @impl AshOpenLineage.CorrelationProvider
  def id do
    case Process.get(@key) do
      nil -> @key |> tap(&Process.put(&1, Ash.UUID.generate())) |> Process.get()
      id -> id
    end
  end

  @impl AshOpenLineage.CorrelationProvider
  def depth, do: 0
end
