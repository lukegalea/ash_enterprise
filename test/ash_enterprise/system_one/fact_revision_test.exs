defmodule AshEnterprise.SystemOne.FactRevisionTest do
  @moduledoc """
  A judgment fact can be REVISED on this host: a second admission with a
  different value splits the fact's period at its `effective_at`, which
  writes a second version row under the same id.

  The facts table's `id` uniqueness must therefore be temporal —
  `(id WITH =, valid_at WITH &&)`, unique at every instant — not a plain
  btree unique index on `id`, which rejects every revision with 23505.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.SystemOne.Fact
  alias AshJudgments.Facts.Materialiser

  @t0 ~U[2026-06-01 12:00:00Z]
  @t1 ~U[2026-06-01 13:00:00Z]

  defp decision(subject_id, value, effective_at) do
    %{
      result: :admitted,
      subject: %{"type" => "commit", "id" => subject_id},
      predicate: "commit_message_imperative",
      value: value,
      holds: value == "imperative",
      grade: :grant,
      admission_id: Ash.UUID.generate(),
      effective_at: effective_at
    }
  end

  defp versions(subject_id, as_of) do
    Fact
    |> Ash.Query.filter(subject_id == ^subject_id)
    |> Ash.Query.as_of(as_of)
    |> Ash.read!(authorize?: false)
  end

  test "a revision splits the period: both versions share the id, each current in its own period" do
    subject_id = "commit-#{System.unique_integer([:positive])}"

    assert {:ok, :materialised} =
             Materialiser.materialise(decision(subject_id, "imperative", @t0))

    assert [original] = versions(subject_id, @t0)

    assert {:ok, :materialised} = Materialiser.materialise(decision(subject_id, "other", @t1))

    # The as-of-now read sees the revision...
    assert [revised] =
             Fact
             |> Ash.Query.filter(subject_id == ^subject_id)
             |> Ash.read!(authorize?: false)

    assert revised.value == "other"
    refute revised.holds
    assert revised.id == original.id
    assert DateTime.compare(revised.valid_at.lower, @t1) == :eq

    # ...and history is preserved: as of T0 the original value still reads.
    assert [before] = versions(subject_id, @t0)
    assert before.value == "imperative"
    assert before.id == original.id
    assert DateTime.compare(before.valid_at.upper, @t1) == :eq
  end

  test "a reassessment round trip: admit, revise, revise back" do
    subject_id = "commit-#{System.unique_integer([:positive])}"
    t2 = DateTime.add(@t1, 3600, :second)

    assert {:ok, :materialised} =
             Materialiser.materialise(decision(subject_id, "imperative", @t0))

    assert {:ok, :materialised} = Materialiser.materialise(decision(subject_id, "other", @t1))
    assert {:ok, :materialised} = Materialiser.materialise(decision(subject_id, "imperative", t2))

    assert [now] = versions(subject_id, DateTime.add(t2, 1, :second))
    assert now.value == "imperative"
    assert [mid] = versions(subject_id, @t1)
    assert mid.value == "other"
    assert [first] = versions(subject_id, @t0)
    assert first.value == "imperative"
    assert Enum.uniq([now.id, mid.id, first.id]) == [now.id]
  end

  test "two versions of one id may never overlap in time" do
    subject_id = "commit-#{System.unique_integer([:positive])}"

    assert {:ok, :materialised} =
             Materialiser.materialise(decision(subject_id, "imperative", @t0))

    assert [fact] = versions(subject_id, @t0)

    # Reusing the id (the caller's idempotency key) for another subject in
    # an overlapping period is what the temporal id identity forbids.
    clash =
      "other-#{System.unique_integer([:positive])}"
      |> decision("imperative", DateTime.add(@t0, 60, :second))
      |> Map.put(:id, fact.id)

    # The exclusion is a constraint Ash knows (`unique_id` on a temporal
    # resource), so it surfaces as an invalid `id`, not an unknown error.
    error = assert_raise Ash.Error.Invalid, fn -> Materialiser.materialise(clash) end
    assert Enum.any?(error.errors, &match?(%Ash.Error.Changes.InvalidAttribute{field: :id}, &1))
  end
end
