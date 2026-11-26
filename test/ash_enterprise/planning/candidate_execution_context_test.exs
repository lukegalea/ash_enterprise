defmodule AshEnterprise.Planning.CandidateExecutionContextTest do
  @moduledoc """
  A candidate's audit events name the execution context they ran in (ADR 0080), taken from
  the `world` its run gave it: `:operational` is `live`, `:scenario` is `scenario`. The
  context is never an input, so a write cannot claim a more live one than its run's.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Planning.TestKit

  require Ash.Query

  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Planning

  setup do
    publish_requirements!()
    %{w: world!()}
  end

  defp events_for(candidate) do
    EventLog
    |> Ash.Query.filter(record_id == ^candidate.id)
    |> Ash.read!(authorize?: false)
  end

  defp propose!(w, run) do
    Planning.propose_planning_candidate!(
      %{run_id: run.id, index: 1, assignments: Jason.encode!([])},
      w.oban
    )
  end

  test "a candidate of an operational run is stamped live", %{w: w} do
    candidate = propose!(w, w.run)

    assert candidate.world == :operational
    assert [_ | _] = events = events_for(candidate)
    assert Enum.all?(events, &(&1.metadata["execution_context"] == "live"))
  end

  test "a candidate of a scenario run is stamped scenario, on every later event", %{w: w} do
    run =
      Planning.request_planning_run!(
        %{
          binding_id: w.binding.id,
          model_version_id: w.mv.id,
          world: :scenario,
          scenario_ref: "what-if-1"
        },
        w.aopts ++ [authorize?: true]
      )

    candidate = propose!(w, run)
    assert candidate.world == :scenario

    Planning.mark_planning_candidate_stale!(candidate, w.oban)

    events = events_for(candidate)
    assert length(events) >= 2
    assert Enum.all?(events, &(&1.metadata["execution_context"] == "scenario"))
  end
end
