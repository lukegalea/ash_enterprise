defmodule AshEnterpriseWeb.TimeTravelLiveTest do
  @moduledoc """
  PROD-47 through the LiveView: `/app/time-travel/people/:id?as_of=` shows
  a golden person as two people before their merge and one after, the
  scrubber patches `?as_of=`, and someone who cannot read the person is
  sent back without seeing anything.

  SYNTHETIC data only.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3, person!: 3]

  alias AshA2ui.AsOf
  alias AshEnterprise.Canonical.Person
  alias AshEnterprise.Mdm.SourceIdentity

  setup %{conn: conn} do
    ctx = tenant!()
    system = [tenant: ctx.tenant, authorize?: false]
    week_ago = DateTime.add(DateTime.utc_now(), -7, :day)

    survivor = person!(ctx, "sam.work@example.test", "Sam Work")
    loser = person!(ctx, "sam.home@example.test", "Sam Home")

    for {golden, external_id} <- [{survivor, "slack:U-sam"}, {loser, "gmail:sam.home"}] do
      SourceIdentity
      |> Ash.Changeset.for_create(
        :open,
        %{
          source: :slack,
          stream: :users,
          external_id: external_id,
          golden_resource: "AshEnterprise.Canonical.Person",
          golden_id: golden.id,
          asserted_by: :mapping
        },
        system ++ [as_of: week_ago]
      )
      |> Ash.create!()
    end

    loser
    |> Ash.Changeset.for_update(:mdm_merge_into, %{survivor_id: survivor.id}, system)
    |> Ash.update!()

    %{
      conn: conn,
      ctx: ctx,
      survivor: survivor,
      before_merge: DateTime.add(week_ago, 1, :day)
    }
  end

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp person_path(person, at), do: AsOf.put_param("/app/time-travel/people/#{person.id}", at)

  test "the index lists the golden people the reader owns", %{conn: conn, ctx: ctx, survivor: s} do
    {:ok, view, _html} = live(sign_in(conn, ctx.user), "/app/time-travel")

    assert has_element?(view, "#time-travel-person-#{s.id}", "Sam Work")

    view |> element("#time-travel-search") |> render_change(%{"q" => "sam.work"})
    assert_patch(view)
    assert has_element?(view, "#time-travel-person-#{s.id}")

    view |> element("#time-travel-search") |> render_change(%{"q" => "nobody-by-that-name"})
    assert_patch(view)
    refute has_element?(view, "#time-travel-person-#{s.id}")
  end

  test "before the merge the golden shows two people; now it shows one", %{
    conn: conn,
    ctx: ctx,
    survivor: survivor,
    before_merge: before_merge
  } do
    conn = sign_in(conn, ctx.user)

    {:ok, view, _html} = live(conn, person_path(survivor, before_merge))
    assert has_element?(view, "#time-travel-resolved h3", "2 people")
    assert has_element?(view, "#time-travel-resolved", "Sam Home")
    assert has_element?(view, "#person-timeline-status", "As of")

    {:ok, view, _html} = live(conn, person_path(survivor, nil))
    assert has_element?(view, "#time-travel-resolved h3", "1 person")
    assert has_element?(view, "#person-timeline-marks", "Merged")
  end

  test "the scrubber moves the page through ?as_of=", %{conn: conn, ctx: ctx, survivor: survivor} do
    {:ok, view, _html} = live(sign_in(conn, ctx.user), person_path(survivor, nil))

    view
    |> element("#person-timeline-form")
    |> render_change(%{"position" => "500"})

    path = assert_patch(view)
    assert path =~ "as_of="
    assert has_element?(view, "#time-travel-resolved h3", "2 people")

    # Back to now through the scrubber's own link.
    view |> element("#person-timeline-now") |> render_click()
    assert_patch(view, "/app/time-travel/people/#{survivor.id}")
    assert has_element?(view, "#time-travel-resolved h3", "1 person")
  end

  # The surface may split its payload across pushes; join them all.
  defp pushed_json(view) do
    assert_push_event(view, "a2ui:messages", %{messages: first}, 2000)
    push_all(view, [JSON.encode!(first)])
  end

  defp push_all(view, acc) do
    assert_push_event(view, "a2ui:messages", %{messages: messages}, 200)
    push_all(view, acc ++ [JSON.encode!(messages)])
  rescue
    ExUnit.AssertionError -> Enum.join(acc, "\n")
  end

  test "the golden surface reads its identities at the same instant, view-only", %{
    conn: conn,
    ctx: ctx,
    survivor: survivor,
    before_merge: before_merge
  } do
    conn = sign_in(conn, ctx.user)
    golden = "/app/mdm/golden?ctx[person]=#{survivor.id}"

    {:ok, view, _html} = live(conn, AsOf.put_param(golden, before_merge))
    assert has_element?(view, "#golden-as-of", "Nothing here can be changed")
    then = pushed_json(view)
    assert then =~ "slack:U-sam"
    refute then =~ "gmail:sam.home"

    {:ok, view, _html} = live(conn, golden)
    refute has_element?(view, "#golden-as-of")
    now = pushed_json(view)
    assert now =~ "slack:U-sam"
    assert now =~ "gmail:sam.home"
  end

  test "a subject's facts read as of the instant", %{conn: conn, ctx: ctx} do
    subject_id = Ash.UUID.generate()
    t0 = ~U[2026-06-01 12:00:00.000000Z]

    for {value, at} <- [{"yes", t0}, {"no", ~U[2026-06-08 12:00:00.000000Z]}] do
      {:ok, :materialised} =
        AshJudgments.Facts.Materialiser.materialise(%{
          result: :admitted,
          subject: %{"type" => "person", "id" => subject_id},
          predicate: "prefers_morning_meetings",
          value: value,
          holds: value == "yes",
          grade: :grant,
          admission_id: Ash.UUID.generate(),
          effective_at: at
        })
    end

    analyst = member!(ctx, "Analyst", [{AshEnterprise.SystemOne.Fact, :read, :global}])
    conn = sign_in(conn, analyst.user)
    path = "/app/time-travel/subjects/#{subject_id}?type=person"

    {:ok, view, _html} = live(conn, AsOf.put_param(path, DateTime.add(t0, 1, :day)))
    assert has_element?(view, "#time-travel-facts-table", "yes (holds)")
    assert has_element?(view, "#facts-timeline-marks", "Revised")

    {:ok, view, _html} = live(conn, path)
    assert has_element?(view, "#time-travel-facts-table", "no (does not hold)")
  end

  test "someone who cannot read the person cannot time-travel them", %{
    conn: conn,
    ctx: ctx,
    survivor: survivor,
    before_merge: before_merge
  } do
    reader = member!(ctx, "Steward", [{Person, :read, :basic}, {SourceIdentity, :read, :global}])

    assert {:error, {:live_redirect, %{to: "/app/time-travel", flash: flash}}} =
             live(sign_in(conn, reader.user), person_path(survivor, before_merge))

    assert flash["error"] =~ "isn't one you can open"
  end
end
