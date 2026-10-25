defmodule Battery.Bpmn.Invoker do
  @moduledoc """
  The battery's `AshBpmn.ActionInvoker`: records invoked action names in an
  ETS table and returns `:ok`. Node execution may run twice under
  redelivery, so the invocation is append-only and side-effect-free.
  """

  @table :battery_bpmn_calls

  def invoke(action, _ctx) do
    ensure_table()
    :ets.insert(@table, {System.unique_integer([:positive]), action, DateTime.utc_now()})
    :ok
  end

  @doc "All recorded invocations, oldest first: `{id, action, timestamp}`."
  def recorded_calls do
    ensure_table()
    :ets.tab2list(@table) |> Enum.sort_by(&elem(&1, 0))
  end

  @doc "Forgets every recorded invocation."
  def clear_calls do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    :ok
  end
end
