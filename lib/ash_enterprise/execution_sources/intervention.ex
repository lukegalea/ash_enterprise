defmodule AshEnterprise.ExecutionSources.Intervention do
  @moduledoc """
  A person's acts on invocations (`AshEnterprise.Execution.Intervention`) as decision
  entries under the invocation acted on: who did what, and why in their own words. A
  rerun's entry does not name the new request, which is the rerunner's: the invocation
  source shows it under the row it reruns to whoever may read it. Reads the interventions on the trace's invocations.
  """

  @behaviour AshAgent.Execution.Source

  alias AshAgent.Execution.Source
  alias AshEnterprise.ExecutionSources

  @impl true
  def read(scope, opts) do
    ExecutionSources.read(
      AshEnterprise.Execution.Intervention,
      [invocation_id: ExecutionSources.uuids(scope, :invocation)],
      opts
    )
  end

  @impl true
  def to_entries(rows), do: Enum.map(rows, &entry/1)

  defp entry(intervention) do
    Source.entry(
      at: intervention.created_on,
      kind: :decision,
      status: :succeeded,
      source_ref: Source.ref(:intervention, intervention.id),
      parent_ref: Source.ref(:invocation, intervention.invocation_id),
      actor_label: ExecutionSources.person_label(intervention.owner_id),
      summary: "#{act(intervention)}: #{intervention.reason}"
    )
  end

  defp act(%{act: :resolve, resolution: resolution}), do: "settled as #{resolution}"
  # The new request is not named: it is the rerunner's, and the invocation source shows
  # it under the row it reruns to whoever may read it.
  defp act(%{act: :rerun}), do: "rerun as a new request"
  defp act(%{act: act}), do: to_string(act)
end
