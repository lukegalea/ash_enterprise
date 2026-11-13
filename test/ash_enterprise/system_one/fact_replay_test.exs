defmodule AshEnterprise.SystemOne.FactReplayTest do
  @moduledoc """
  `FactReplay.decisions_from_event_log/1` reads the facts table's decisions back
  out of the audit log at the instants they took effect. A back-dated admission is
  written now and takes effect earlier, so the instant is the event's `as_of`, not
  its `occurred_at`.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.SystemOne.Fact
  alias AshEnterprise.SystemOne.FactReplay
  alias AshJudgments.Facts.Materialiser

  @predicate "commit_message_imperative"

  @t1 ~U[2025-01-10 00:00:00Z]
  @t2 ~U[2025-06-01 00:00:00Z]
  @t3 ~U[2025-09-01 00:00:00Z]

  defp materialise(subject_id, overrides) do
    [
      result: :admitted,
      subject: %{"type" => "commit", "id" => subject_id},
      predicate: @predicate,
      value: "imperative",
      holds: true,
      grade: :grant,
      admission_id: Ash.UUID.generate()
    ]
    |> Keyword.merge(overrides)
    |> Materialiser.materialise(resource: Fact)
  end

  defp summary(decisions) do
    Enum.map(decisions, fn decision ->
      {decision.subject["id"], decision.result, decision[:value],
       DateTime.to_unix(decision.effective_at, :microsecond)}
    end)
  end

  defp usec(datetime), do: DateTime.to_unix(datetime, :microsecond)

  test "decisions take effect at the write's as_of, in that order" do
    # Recorded in this order, all of them now. The second subject's admission is
    # recorded first and takes effect last.
    {:ok, :materialised} = materialise("later", effective_at: @t3)
    {:ok, :materialised} = materialise("earlier", effective_at: @t1)
    {:ok, :materialised} = materialise("earlier", value: "past", holds: false, effective_at: @t2)
    {:ok, :superseded} = materialise("earlier", result: :omitted, effective_at: @t3)

    {:ok, decisions} = FactReplay.decisions_from_event_log()

    assert summary(decisions) == [
             {"earlier", :admitted, "imperative", usec(@t1)},
             {"earlier", :admitted, "past", usec(@t2)},
             {"later", :admitted, "imperative", usec(@t3)},
             {"earlier", :omitted, nil, usec(@t3)}
           ]

    # A revision's event carries only the revised fields; the rest come from the
    # record's payload.
    revised = Enum.at(decisions, 1)
    assert revised.predicate == @predicate
    assert revised.holds == false
  end
end
