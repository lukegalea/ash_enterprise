defmodule Mix.Tasks.AshEnterprise.SystemOne.ReplayFactsTest do
  @moduledoc """
  `mix ash_enterprise.system_one.replay_facts` rebuilds the facts table from
  its audit event log. A fact a person admitted comes back at the person's
  grade, so an automatic admission after the rebuild still cannot overwrite
  it. SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Repo
  alias AshEnterprise.SystemOne.Fact
  alias AshJudgments.Facts.Materialiser
  alias Mix.Tasks.AshEnterprise.SystemOne.ReplayFacts

  @predicate "prefers_morning_meetings"
  @t0 ~U[2026-06-01 12:00:00.000000Z]
  @t1 ~U[2026-06-08 12:00:00.000000Z]

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    %{subject: %{"type" => "person", "id" => Ash.UUID.generate()}}
  end

  defp admit(subject, grade, value, effective_at) do
    Materialiser.materialise(%{
      result: :admitted,
      subject: subject,
      predicate: @predicate,
      value: value,
      holds: value == "yes",
      grade: grade,
      admission_id: Ash.UUID.generate(),
      effective_at: effective_at
    })
  end

  defp facts, do: Ash.read!(Fact, authorize?: false)

  test "a person-admitted fact is rebuilt at the person's grade", %{subject: subject} do
    assert {:ok, :materialised} = admit(subject, :person, "yes", @t0)

    # Raw SQL on purpose: facts have no action that deletes history, and the
    # task rebuilds an emptied table (the cut-over's new one). The sandbox
    # rolls it back.
    Repo.query!("DELETE FROM system_one_facts")
    assert facts() == []

    ReplayFacts.run([])
    assert_received {:mix_shell, :info, ["\nReplayed 1 decision(s) — materialised: 1."]}

    assert [%{admission_grade: :person, value: "yes"}] = facts()

    assert {:ok, :kept_person_fact} = admit(subject, :grant, "no", @t1)
    assert [%{admission_grade: :person, value: "yes"}] = facts()
  end
end
