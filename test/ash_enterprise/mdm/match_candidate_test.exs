defmodule AshEnterprise.Mdm.MatchCandidateTest do
  @moduledoc """
  The steward verdict gate (MDM-4, ADR 0050 §ActorContext): confirming or
  rejecting a review-banded match is a person's act — both system actor
  kinds are refused, and a person's decision is recorded as provenance.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Mdm.TestSupport

  alias AshEnterprise.Mdm.MatchCandidate
  alias AshEnterprise.Platform.Seeder

  require Ash.Query

  setup do
    %{organization: organization, user: admin} =
      Seeder.seed_tenant(
        name: "Cand #{System.unique_integer([:positive])}",
        unique_name: "cand-#{System.unique_integer([:positive])}"
      )

    {:ok, org: organization.id, admin: admin}
  end

  defp review_candidate!(org, admin),
    do: {candidate, _staged, _golden} = staged_candidate!(org, admin, "Ann Dup", "ann2@x.io")

  test "reject is not a dead end: the row becomes its own golden", %{org: org, admin: admin} do
    {candidate, staged, _golden} = review_candidate!(org, admin)

    candidate
    |> Ash.Changeset.for_update(:reject, %{}, tenant: org, actor: admin)
    |> Ash.update!(tenant: org, actor: admin)

    # No pending candidate needs the row, so it becomes a golden of its own —
    # "not that golden" is not "no golden".
    reloaded = Ash.get!(AshEnterprise.Mdm.StagedRecord, staged.id, tenant: org, authorize?: false)
    assert reloaded.status == :rejected

    goldens =
      AshEnterprise.Canonical.Person
      |> Ash.Query.filter(name == ^"Ann Dup")
      |> Ash.read!(tenant: org, authorize?: false)

    assert length(goldens) == 1

    assert [%{}] =
             AshEnterprise.Mdm.SourceIdentity
             |> Ash.Query.filter(golden_id == ^hd(goldens).id)
             |> Ash.read!(tenant: org, authorize?: false)
  end

  test "the machine update cannot write a person state", %{org: org, admin: admin} do
    {candidate, _staged, _golden} = review_candidate!(org, admin)

    assert {:error, %Ash.Error.Invalid{}} =
             candidate
             |> Ash.Changeset.for_update(:update, %{status: :confirmed},
               tenant: org,
               actor: AshEnterprise.Platform.SystemActor.system()
             )
             |> Ash.update(tenant: org, actor: AshEnterprise.Platform.SystemActor.system())
  end

  test "a system actor is forbidden to decide", %{org: org, admin: admin} do
    {candidate, _staged, _golden} = review_candidate!(org, admin)

    for actor <- [
          AshEnterprise.Platform.SystemActor.replay(),
          AshEnterprise.Platform.SystemActor.ai()
        ] do
      assert {:error, %Ash.Error.Forbidden{}} =
               candidate
               |> Ash.Changeset.for_update(:confirm, %{}, tenant: org, actor: actor)
               |> Ash.update(tenant: org, actor: actor)
    end
  end

  test "a person's decision is recorded as provenance", %{org: org, admin: admin} do
    {candidate, staged, golden} = review_candidate!(org, admin)

    confirmed =
      candidate
      |> Ash.Changeset.for_update(:confirm, %{}, tenant: org, actor: admin)
      |> Ash.update!(tenant: org, actor: admin)

    assert confirmed.status == :confirmed
    assert to_string(confirmed.human_verdict_ref["verdict"]) == "confirm"

    # The observation and the person's answer exist on the System One ledger.
    verdict =
      AshEnterprise.SystemOne.HumanVerdict
      |> Ash.Query.filter(id == ^confirmed.human_verdict_ref["verdict_id"])
      |> Ash.read_one!(tenant: org, authorize?: false)

    assert to_string(verdict.human_value) == "match"
    assert verdict.reviewer == to_string(admin.email)
    assert verdict.basis == :review_task

    judgment =
      AshEnterprise.SystemOne.Judgment
      |> Ash.Query.filter(id == ^confirmed.human_verdict_ref["judgment_id"])
      |> Ash.read_one!(tenant: org, authorize?: false)

    # The created person exists exactly once with the staged values folded in.
    reloaded_golden =
      Ash.get!(AshEnterprise.Canonical.Person, golden.id, tenant: org, authorize?: false)

    assert to_string(reloaded_golden.name) == "Ann Dup Existing"

    assert judgment.family == "mdm_matches"
    assert judgment.subject_id == candidate.id

    # The act: the staged record merged into the golden — survivorship
    # filled the golden's gaps, the identity opened at the golden, and the
    # staged row is spent.
    reloaded = Ash.get!(AshEnterprise.Canonical.Person, golden.id, tenant: org, authorize?: false)
    assert to_string(reloaded.email) == "ann2@x.io"

    assert to_string(
             Ash.get!(AshEnterprise.Mdm.StagedRecord, staged.id, tenant: org, authorize?: false).status
           ) == "merged"

    identities =
      AshEnterprise.Mdm.SourceIdentity
      |> Ash.Query.filter(golden_id == ^golden.id)
      |> Ash.read!(tenant: org, authorize?: false)

    assert [%{}] = identities
  end
end
