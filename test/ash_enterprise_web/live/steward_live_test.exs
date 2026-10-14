defmodule AshEnterpriseWeb.StewardLiveTest do
  @moduledoc """
  The steward queue driven through the actual LiveView: a review-banded
  candidate appears, a person confirms it (status + verdict provenance on
  the row), and the queue empties.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AshEnterprise.Mdm.TestSupport

  alias AshEnterprise.Mdm.MatchCandidate
  alias AshEnterprise.Platform.Seeder

  require Ash.Query

  setup %{conn: conn} do
    %{organization: organization, user: admin} =
      Seeder.seed_tenant(
        name: "Steward #{System.unique_integer([:positive])}",
        unique_name: "steward-#{System.unique_integer([:positive])}"
      )

    %{conn: sign_in(conn, admin), org: organization.id, admin: admin}
  end

  # Same session shape the legacy live test documents: the User resource
  # requires token presence, so the session carries a JWT.
  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp review_candidate!(org, admin) do
    {candidate, _staged, _golden} = staged_candidate!(org, admin, "Ann Dup", "ann2@x.io")
    candidate
  end

  test "review-banded candidates render with their acts", %{conn: conn, org: org, admin: admin} do
    candidate = review_candidate!(org, admin)

    {:ok, _view, html} = live(conn, "/app/mdm")

    assert html =~ "Steward queue"
    assert html =~ "candidate-#{candidate.id}"
    assert html =~ "email_exact"
  end

  test "a person confirms: the candidate is decided and provenance recorded", %{
    conn: conn,
    org: org,
    admin: admin
  } do
    candidate = review_candidate!(org, admin)
    {:ok, view, _html} = live(conn, "/app/mdm")

    view
    |> element("#confirm-#{candidate.id}")
    |> render_click()

    decided = Ash.get!(MatchCandidate, candidate.id, tenant: org, authorize?: false)
    assert decided.status == :confirmed
    assert to_string(decided.human_verdict_ref["verdict"]) == "confirm"

    verdict =
      AshEnterprise.SystemOne.HumanVerdict
      |> Ash.Query.filter(id == ^decided.human_verdict_ref["verdict_id"])
      |> Ash.read_one!(tenant: org, authorize?: false)

    assert verdict.reviewer == to_string(admin.email)

    # The queue is empty again: the decided candidate left it.
    refute render(view) =~ candidate.id
    assert render(view) =~ "queue is empty"
  end

  test "a person rejects: the candidate stands alone", %{conn: conn, org: org, admin: admin} do
    candidate = review_candidate!(org, admin)
    {:ok, view, _html} = live(conn, "/app/mdm")

    view
    |> element("#reject-#{candidate.id}")
    |> render_click()

    decided = Ash.get!(MatchCandidate, candidate.id, tenant: org, authorize?: false)
    assert decided.status == :rejected
    assert to_string(decided.human_verdict_ref["verdict"]) == "reject"
  end

  test "a decided candidate cannot be decided again", %{conn: conn, org: org, admin: admin} do
    candidate = review_candidate!(org, admin)

    {:ok, view, _html} = live(conn, "/app/mdm")
    view |> element("#confirm-#{candidate.id}") |> render_click()

    # Re-deciding through the action directly hits the validate gate.
    fresh = Ash.get!(MatchCandidate, candidate.id, tenant: org, authorize?: false)

    assert {:error, %Ash.Error.Invalid{}} =
             fresh
             |> Ash.Changeset.for_update(:confirm, %{}, tenant: org, authorize?: false)
             |> Ash.update(tenant: org, authorize?: false)
  end
end
