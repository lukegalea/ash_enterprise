defmodule AshEnterprise.SystemOne.FactPrimaryKeyTest do
  @moduledoc """
  The facts table carries the primary key its resource snapshot records:
  `PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)`, named `system_one_facts_pkey`.

  The table was first created without it, and the migration generator
  cannot see a missing key, so the key arrives through the
  `AshJudgments.Facts.TemporalPrimaryKey` custom statement on
  `AshEnterprise.SystemOne.Fact`. The name matters as much as the shape:
  ash_postgres reports a key violation as an overlapping `valid_at` only
  when the constraint is named `<table>_pkey`, and any later key
  migration drops it by that name.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Repo
  alias AshEnterprise.SystemOne.Fact
  alias AshJudgments.Facts.Materialiser

  @t0 ~U[2026-06-01 12:00:00Z]

  defp decision(subject_id, effective_at) do
    %{
      result: :admitted,
      subject: %{"type" => "commit", "id" => subject_id},
      predicate: "commit_message_imperative",
      value: "imperative",
      holds: true,
      grade: :grant,
      admission_id: Ash.UUID.generate(),
      effective_at: effective_at
    }
  end

  test "the table has the temporal primary key under the canonical name" do
    %{rows: rows} =
      Repo.query!("""
      SELECT conname, pg_get_constraintdef(oid)
      FROM pg_constraint
      WHERE conrelid = 'system_one_facts'::regclass AND contype = 'p'
      """)

    assert rows == [["system_one_facts_pkey", "PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)"]]
  end

  test "the key alone refuses an overlapping version of the same id" do
    subject_id = "commit-#{System.unique_integer([:positive])}"
    assert {:ok, :materialised} = Materialiser.materialise(decision(subject_id, @t0))

    [fact] =
      Fact
      |> Ash.Query.filter(subject_id == ^subject_id)
      |> Ash.read!(authorize?: false)

    # The `unique_id` exclusion refuses the same overlap, so it is dropped
    # inside this test's sandbox transaction (rolled back with it) to leave
    # the primary key as the only guard.
    Repo.query!("ALTER TABLE system_one_facts DROP CONSTRAINT system_one_facts_unique_id_index")

    clash =
      "other-#{System.unique_integer([:positive])}"
      |> decision(DateTime.add(@t0, 60, :second))
      |> Map.put(:id, fact.id)

    # Without the key the write succeeds; with it, ash_postgres reports the
    # overlap on the period and names the constraint that refused it.
    error = assert_raise Ash.Error.Invalid, fn -> Materialiser.materialise(clash) end

    assert [%Ash.Error.Changes.InvalidAttribute{field: :valid_at} = refusal] =
             Enum.filter(error.errors, &match?(%Ash.Error.Changes.InvalidAttribute{}, &1))

    assert refusal.private_vars[:constraint] == "system_one_facts_pkey"
  end
end
