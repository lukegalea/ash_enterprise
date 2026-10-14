defmodule AshEnterpriseWeb.StewardLiveTest do
  @moduledoc """
  The steward queue driven through the actual LiveView: a review-banded
  candidate appears, a person confirms it (status + verdict provenance on
  the row), and the queue empties.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshEnterprise.Mdm.MatchCandidate
  alias AshEnterprise.Platform.Seeder

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

  defp review_candidate!(org) do
    MatchCandidate
    |> Ash.Changeset.for_create(:create, %{
      staged_record_id: Ash.UUID.generate(),
      golden_resource: "AshEnterprise.Canonical.Person",
      golden_id: Ash.UUID.generate(),
      score: Decimal.new("0.72"),
      explanation: %{"rules" => [%{"rule" => "email_exact", "score" => "1.0"}]}
    })
    |> Ash.create!(tenant: org, authorize?: false)
    |> then(fn candidate ->
      candidate
      |> Ash.Changeset.for_update(:update, %{band: :review}, tenant: org, authorize?: false)
      |> Ash.update!(tenant: org, authorize?: false)
    end)
  end

  test "review-banded candidates render with their acts", %{conn: conn, org: org} do
    candidate = review_candidate!(org)

    {:ok, _view, html} = live(conn, "/app/steward")

    assert html =~ "Steward queue"
    assert html =~ "candidate-#{candidate.id}"
    assert html =~ "email_exact"
  end

  test "a person confirms: the candidate is decided and provenance recorded", %{
    conn: conn,
    org: org,
    admin: admin
  } do
    candidate = review_candidate!(org)
    {:ok, view, _html} = live(conn, "/app/steward")

    view
    |> element("#confirm-#{candidate.id}")
    |> render_click()

    decided = Ash.get!(MatchCandidate, candidate.id, tenant: org, authorize?: false)
    assert decided.status == :confirmed
    assert to_string(decided.human_verdict_ref["verdict"]) == "confirm"
    assert to_string(decided.human_verdict_ref["by"]) == to_string(admin.id)

    # The queue is empty again: the decided candidate left it.
    refute render(view) =~ candidate.id
    assert render(view) =~ "queue is empty"
  end

  test "a person rejects: the candidate stands alone", %{conn: conn, org: org} do
    candidate = review_candidate!(org)
    {:ok, view, _html} = live(conn, "/app/steward")

    view
    |> element("#reject-#{candidate.id}")
    |> render_click()

    decided = Ash.get!(MatchCandidate, candidate.id, tenant: org, authorize?: false)
    assert decided.status == :rejected
    assert to_string(decided.human_verdict_ref["verdict"]) == "reject"
  end

  test "a decided candidate cannot be decided again", %{conn: conn, org: org} do
    candidate = review_candidate!(org)

    {:ok, view, _html} = live(conn, "/app/steward")
    view |> element("#confirm-#{candidate.id}") |> render_click()

    # Re-deciding through the action directly hits the validate gate.
    fresh = Ash.get!(MatchCandidate, candidate.id, tenant: org, authorize?: false)

    assert {:error, %Ash.Error.Invalid{}} =
             fresh
             |> Ash.Changeset.for_update(:confirm, %{}, tenant: org, authorize?: false)
             |> Ash.update(tenant: org, authorize?: false)
  end
end
