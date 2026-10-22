defmodule AshEnterpriseWeb.CalendarTimeTravelLiveTest do
  @moduledoc """
  `/app/calendar?week=&as_of=` through the real LiveView (PROD-47): the grid
  opens on the week and shows it as it was known at the instant, the
  scrubber carries the week's reschedules as marks and moves the instant,
  and another person sees none of it. SYNTHETIC data only.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AshEnterprise.Test.DailyFixtures

  alias AshA2ui.AsOf

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  setup %{conn: conn} do
    ctx = tenant!()
    moved = DateTime.add(DateTime.utc_now(), -1, :day)

    event =
      event!(ctx, "SYNTHETIC design review", 0, 30,
        starts_at: ~U[2030-03-19 10:00:00.000000Z],
        as_of: DateTime.add(DateTime.utc_now(), -3, :day)
      )

    reproject_event!(
      ctx,
      event,
      %{starts_at: ~U[2030-03-20 14:00:00.000000Z], ends_at: ~U[2030-03-20 14:30:00.000000Z]},
      as_of: moved
    )

    %{conn: conn, ctx: ctx, event: event, moved: moved}
  end

  defp bootstrap(view) do
    assert_push_event(view, "a2ui:messages", %{messages: messages}, 5_000)

    Enum.find_value(messages, fn
      %{"createSurface" => %{"dataModel" => model}} -> model
      _other -> nil
    end)
  end

  defp week_path(at), do: AsOf.put_param("/app/calendar?week=2030-03-18", at)

  defp days(model), do: Enum.map(model["records"]["table"], &{&1["title"], &1["_calendar_start"]})

  test "the week as it was known before the reschedule, and after it", %{
    conn: conn,
    ctx: ctx,
    moved: moved
  } do
    conn = sign_in(conn, ctx.user)

    {:ok, view, html} = live(conn, week_path(DateTime.add(moved, -1, :minute)))
    assert html =~ "Your calendar as it was known on"

    model = bootstrap(view)
    window = model["query"]["table"]["window"]

    assert {window["granularity"], window["from"], window["to"]} ==
             {"week", "2030-03-18", "2030-03-24"}

    assert days(model) == [{"SYNTHETIC design review", "2030-03-19"}]

    # The reschedule is a mark on the scrubber, linked to its own instant.
    render_async(view)
    assert has_element?(view, "#calendar-timeline-mark-0", "Moved: SYNTHETIC design review")

    assert has_element?(
             view,
             ~s(#calendar-timeline-mark-0[href="#{week_path(moved)}"])
           )

    {:ok, after_view, _html} = live(sign_in(build_conn(), ctx.user), week_path(moved))
    assert days(bootstrap(after_view)) == [{"SYNTHETIC design review", "2030-03-20"}]

    # Scrubbing all the way right is now: the same week, live. A new instant
    # rebuilds the surface (pinned and live ones carry different controls).
    view |> element("#calendar-timeline-form") |> render_change(%{"position" => "1000"})
    assert_redirect(view, "/app/calendar?week=2030-03-18")

    {:ok, live_view, html} =
      live(sign_in(build_conn(), ctx.user), "/app/calendar?week=2030-03-18")

    refute html =~ "as it was known"
    assert days(bootstrap(live_view)) == [{"SYNTHETIC design review", "2030-03-20"}]
    render_async(live_view)
    assert has_element?(live_view, "#calendar-timeline-mark-0", "Moved: SYNTHETIC design review")
  end

  test "the live calendar offers the week's time travel and is unchanged otherwise", %{
    conn: conn,
    ctx: ctx
  } do
    {:ok, view, html} = live(sign_in(conn, ctx.user), "/app/calendar")
    refute html =~ "as it was known"
    assert has_element?(view, "#calendar-time-travel")
    refute has_element?(view, "#calendar-timeline")
    assert bootstrap(view)["query"]["table"]["window"]["granularity"] == "month"
  end

  test "another person sees neither the week then nor its reschedules", %{
    conn: conn,
    ctx: ctx,
    moved: moved
  } do
    other = member!(ctx, "SYNTHETIC no grants", [])

    {:ok, view, _html} =
      live(sign_in(conn, other.user), week_path(DateTime.add(moved, -1, :minute)))

    assert days(bootstrap(view)) == []

    render_async(view)
    refute has_element?(view, "#calendar-timeline-mark-0")
    assert has_element?(view, "#calendar-no-moves")
  end
end
