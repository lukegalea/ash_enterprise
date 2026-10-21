defmodule AshEnterprise.SystemOne.FactHistoryTest do
  @moduledoc """
  PROD-47: what was true about a subject at a point in time. A fact read as
  of T returns the value true then; the history marks the admission, the
  revision and the withdrawal. Fact reads stay role-gated in the past.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]

  alias AshEnterprise.SystemOne.{Fact, FactHistory}
  alias AshJudgments.Facts.Materialiser

  @t0 ~U[2026-06-01 12:00:00.000000Z]
  @t1 ~U[2026-06-08 12:00:00.000000Z]

  defp admit!(subject_id, value, effective_at) do
    assert {:ok, :materialised} =
             Materialiser.materialise(%{
               result: :admitted,
               subject: %{"type" => "person", "id" => subject_id},
               predicate: "prefers_morning_meetings",
               value: value,
               holds: value == "yes",
               grade: :grant,
               admission_id: Ash.UUID.generate(),
               effective_at: effective_at
             })
  end

  setup do
    ctx = tenant!()
    analyst = member!(ctx, "Analyst", [{Fact, :read, :global}])
    subject_id = Ash.UUID.generate()

    admit!(subject_id, "yes", @t0)
    admit!(subject_id, "no", @t1)

    %{ctx: ctx, analyst: analyst, subject: %{type: "person", id: subject_id}}
  end

  defp opts(person), do: [actor: person.actor, tenant: person.tenant]

  test "a fact read as of T returns the then-true value", %{analyst: analyst, subject: subject} do
    assert [then] = FactHistory.at(subject, DateTime.add(@t0, 1, :day), opts(analyst))
    assert then.value == "yes"
    assert then.holds

    assert [now] = FactHistory.at(subject, nil, opts(analyst))
    assert now.value == "no"
    refute now.holds

    assert [] = FactHistory.at(subject, DateTime.add(@t0, -1, :day), opts(analyst))
  end

  test "the history marks the admission and the revision", %{analyst: analyst, subject: subject} do
    %{marks: marks} = FactHistory.history(subject, opts(analyst))

    assert [admitted, revised] = marks
    assert admitted.kind == :admitted
    assert DateTime.compare(admitted.at, @t0) == :eq
    assert revised.kind == :revised
    assert DateTime.compare(revised.at, @t1) == :eq
    assert revised.description =~ "yes (holds) → no (does not hold)"
  end

  test "a type-less subject matches every type", %{analyst: analyst, subject: subject} do
    assert [_fact] = FactHistory.at(%{subject | type: nil}, nil, opts(analyst))
    assert [] = FactHistory.at(%{subject | type: "commit"}, nil, opts(analyst))
  end

  test "without a Fact grant, the past is as closed as the present", %{ctx: ctx, subject: subject} do
    outsider = member!(ctx, "Outsider", [])

    assert [] = FactHistory.at(subject, nil, opts(outsider))
    assert [] = FactHistory.at(subject, DateTime.add(@t0, 1, :day), opts(outsider))
    assert %{marks: []} = FactHistory.history(subject, opts(outsider))
  end
end
