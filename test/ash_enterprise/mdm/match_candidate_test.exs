defmodule AshEnterprise.Mdm.MatchCandidateTest do
  @moduledoc """
  The steward verdict gate (MDM-4, ADR 0050 §ActorContext): confirming or
  rejecting a review-banded match is a person's act — both system actor
  kinds are refused, and a person's decision is recorded as provenance.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Mdm.MatchCandidate
  alias AshEnterprise.Platform.Seeder

  setup do
    %{organization: organization, user: admin} =
      Seeder.seed_tenant(
        name: "Cand #{System.unique_integer([:positive])}",
        unique_name: "cand-#{System.unique_integer([:positive])}"
      )

    {:ok, org: organization.id, admin: admin}
  end

  defp review_candidate!(org) do
    MatchCandidate
    |> Ash.Changeset.for_create(:create, %{
      staged_record_id: Ash.UUID.generate(),
      golden_resource: "AshEnterprise.Canonical.Person",
      golden_id: Ash.UUID.generate(),
      score: Decimal.new("0.72"),
      explanation: %{}
    })
    |> Ash.create!(tenant: org, authorize?: false)
    |> then(fn candidate ->
      candidate
      |> Ash.Changeset.for_update(:update, %{band: :review}, tenant: org, authorize?: false)
      |> Ash.update!(tenant: org, authorize?: false)
    end)
  end

  test "a system actor is forbidden to decide", %{org: org} do
    candidate = review_candidate!(org)

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
    candidate = review_candidate!(org)

    confirmed =
      candidate
      |> Ash.Changeset.for_update(:confirm, %{}, tenant: org, actor: admin)
      |> Ash.update!(tenant: org, actor: admin)

    assert confirmed.status == :confirmed
    assert to_string(confirmed.human_verdict_ref["by"]) == to_string(admin.id)
  end
end
