defmodule Battery.Lineage.Capture do
  @moduledoc """
  An `AshOpenLineage.Transport` that keeps every event it is handed, with the meta the
  notifier passed, for a test to read. Raise-free. The store is an unlinked Agent started on
  first use, so it outlives the process that first wrote to it.
  """

  @behaviour AshOpenLineage.Transport

  import Kernel, except: [send: 2]

  @name __MODULE__

  @impl AshOpenLineage.Transport
  def send(event), do: send(event, %{})

  @impl AshOpenLineage.Transport
  def send(event, meta) do
    ensure()
    Agent.update(@name, &[{event, meta} | &1])
    :ok
  end

  @doc "Every captured `{event, meta}`, oldest first."
  @spec events() :: [{map(), map()}]
  def events do
    ensure()
    @name |> Agent.get(& &1) |> Enum.reverse()
  end

  @doc "Forget everything captured."
  @spec clear() :: :ok
  def clear do
    ensure()
    Agent.update(@name, fn _ -> [] end)
  end

  defp ensure do
    case Agent.start(fn -> [] end, name: @name) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
