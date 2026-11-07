defmodule AshEnterprise.Execution.ReviewPacketSectionsTest do
  @moduledoc """
  The review packet's evidence and decisions when the request's trace could not be read
  whole (AGT-51): a source that failed, timed out, did not answer, has more, or is
  missing from the reports makes the section incomplete, and the reviewer is never told
  that no decision was evaluated or that nothing was recorded. A gap entry is not
  evidence.
  """

  use ExUnit.Case, async: true

  alias AshAgent.Execution.Source
  alias AshEnterprise.Bpmn.Calculations.ReviewPacket, as: Render
  alias AshEnterprise.Execution.ReviewPacket
  alias AshEnterprise.ExecutionSources

  @invocation %{
    preconditions: [],
    run_id: nil,
    process_instance_id: nil,
    parent_invocation_id: nil
  }

  defp reports(overrides) do
    for name <- ExecutionSources.names() do
      %{source: name, status: Keyword.get(overrides, name, :complete), cursor: nil, error: nil}
    end
  end

  defp gap(name) do
    [
      at: DateTime.utc_now(),
      kind: :observation,
      status: :uncertain,
      source_ref: Source.ref(:source, name),
      recorded?: false,
      summary: "#{name} not read"
    ]
    |> Source.entry()
    |> Map.put(:source, name)
  end

  defp decision do
    [
      at: DateTime.utc_now(),
      kind: :decision,
      status: :succeeded,
      source_ref: Source.ref(:evaluation, Ash.UUID.generate()),
      definition_ref: "credentialing.review_route@2",
      summary: "routed: rule_route"
    ]
    |> Source.entry()
    |> Map.put(:source, :evaluation)
  end

  test "decision records read whole and empty: no decision was evaluated" do
    decisions = ReviewPacket.decisions({:ok, [], reports([])})
    assert decisions == {:ok, []}
    assert Render.render(:decisions, decisions) == "No decision was evaluated."

    assert Render.render(:evidence, ReviewPacket.evidence(@invocation, {:ok, [], reports([])})) ==
             "None recorded."
  end

  for status <- [:failed, :timed_out, :unanswered, :more] do
    test "an evaluation source that is #{status} is never read as no decision" do
      trace = {:ok, [gap(:evaluation)], reports(evaluation: unquote(status))}

      decisions = ReviewPacket.decisions(trace)
      assert {:incomplete, [], _why} = decisions
      text = Render.render(:decisions, decisions)
      refute text =~ "No decision was evaluated"
      assert text =~ "Unknown: evaluation could not be read in full."

      evidence = ReviewPacket.evidence(@invocation, trace)
      assert {:incomplete, refs, _why} = evidence
      refute "source:evaluation" in refs
      refute Render.render(:evidence, evidence) == "None recorded."
    end
  end

  test "a source missing from the reports is unread, not complete" do
    trace = {:ok, [], Enum.reject(reports([]), &(&1.source == :evaluation))}
    assert {:incomplete, [], {:unread, [:evaluation]}} = ReviewPacket.decisions(trace)
  end

  test "decisions found beside an unread source are shown, and the gap is said" do
    found = decision()
    trace = {:ok, [found], reports(evaluation: :more)}

    assert {:incomplete, [%{summary: "routed: rule_route"}], _} = ReviewPacket.decisions(trace)
    text = Render.render(:decisions, ReviewPacket.decisions(trace))
    assert text =~ "routed: rule_route"
    assert text =~ "Unknown:"
  end

  test "an unreadable trace or no correlation id is unknown, never none" do
    for why <- [:unread, :no_correlation] do
      assert Render.render(:decisions, ReviewPacket.decisions({:unknown, why})) =~ "Unknown:"

      assert Render.render(:evidence, ReviewPacket.evidence(@invocation, {:unknown, why})) =~
               "Unknown:"
    end
  end

  test "the work a request belongs to is cited only where the viewer's trace holds it" do
    run_id = Ash.UUID.generate()
    invocation = %{@invocation | run_id: run_id}

    assert {:ok, []} = ReviewPacket.evidence(invocation, {:ok, [], reports([])})

    held =
      [
        at: DateTime.utc_now(),
        kind: :logical_operation,
        status: :succeeded,
        source_ref: "run:#{run_id}"
      ]
      |> Source.entry()
      |> Map.put(:source, :run)

    assert {:ok, ["run:" <> ^run_id]} =
             ReviewPacket.evidence(invocation, {:ok, [held], reports([])})
  end
end
