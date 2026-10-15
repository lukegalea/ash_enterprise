defmodule AshEnterprise.Mdm.DemoDataTest do
  @moduledoc """
  The demo seed: one populate leaves exactly one review-banded candidate
  pending, Nadia's golden created and a merged duplicate on disk; a second
  populate changes nothing (idempotent — the demo task is safe to re-run).
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Canonical.Person
  alias AshEnterprise.Mdm.{DemoData, MatchCandidate}
  alias AshEnterprise.Platform.Seeder

  require Ash.Query

  setup do
    %{organization: org, user: admin} =
      Seeder.seed_tenant(
        name: "Demo #{System.unique_integer([:positive])}",
        unique_name: "demo-#{System.unique_integer([:positive])}"
      )

    %{org: org.id, admin: admin}
  end

  test "populate leaves one pending review candidate, the new golden and the merged loser", %{
    org: org,
    admin: admin
  } do
    counts = DemoData.populate(org, admin)

    assert counts.review_pending == 1
    assert counts.merged >= 1

    assert Person
           |> Ash.Query.filter(email == ^"nadia@x.io")
           |> Ash.exists?(tenant: org, authorize?: false)

    candidate =
      MatchCandidate
      |> Ash.Query.filter(band == ^:review and status == ^:pending)
      |> Ash.read_one!(tenant: org, authorize?: false)

    assert candidate != nil

    loser =
      Person
      |> Ash.Query.filter(merged == true)
      |> Ash.read_one!(tenant: org, authorize?: false)

    assert to_string(loser.name) == "Ann Duplicate"
    assert loser.master_id != nil
  end

  test "populate is idempotent", %{org: org, admin: admin} do
    first = DemoData.populate(org, admin)
    second = DemoData.populate(org, admin)

    assert first == second
  end
end
