defmodule AshEnterprise.ExecutionSources.Step do
  @moduledoc """
  A run's journal (`AshEnterprise.Execution.Step`) as execution entries, under the run: a
  model turn is a proposal (the tools it called, by name), a tool's result or a message
  the run added is an observation. A step's content is never in its entry; a step whose
  content was erased is not recorded (`recorded?` false).
  """

  @behaviour AshAgent.Execution.Source

  alias AshAgent.Execution.Source
  alias AshEnterprise.ExecutionSources

  @impl true
  def read(scope, opts) do
    ExecutionSources.read(
      AshEnterprise.Execution.Step,
      [run_id: ExecutionSources.uuids(scope, :run)],
      opts,
      load: [:recorded?]
    )
  end

  @impl true
  def to_entries(rows), do: Enum.map(rows, &entry/1)

  defp entry(step) do
    Source.entry(
      at: step.created_on,
      kind: if(step.role == :assistant, do: :proposal, else: :observation),
      status: :succeeded,
      source_ref: Source.ref(:step, step.id),
      parent_ref: Source.ref(:run, step.run_id),
      recorded?: step.recorded? == true,
      summary: summary(step)
    )
  end

  defp summary(%{role: :assistant, seq: seq, tool_calls: [_ | _] = calls}),
    do: "step #{seq}: model turn calling #{Enum.map_join(calls, ", ", &(&1["name"] || "?"))}"

  defp summary(%{role: :assistant, seq: seq}), do: "step #{seq}: model turn"
  defp summary(%{role: :tool, seq: seq}), do: "step #{seq}: tool result"
  defp summary(%{seq: seq}), do: "step #{seq}: message added by the run"
end
