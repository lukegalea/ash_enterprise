defmodule AshEnterpriseWeb.CalendarLiveTest do
  @moduledoc """
  `/app/calendar` through the real LiveView: the surface is a calendar
  (`calendarView` over the event grid, Month / Week switchable); moving the
  window reads that month's or week's events, marked on display-zone days;
  and the agenda presets switch the range, moving the grid to it.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AshEnterprise.Test.DailyFixtures

  alias AshEnterprise.Platform.LocalTime

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  setup %{conn: conn} do
    ctx = tenant!(operator?: true)
    %{conn: sign_in(conn, ctx.user), ctx: ctx}
  end

  defp in_zone(zone) do
    previous = Application.get_env(:ash_enterprise, :display_time_zone)
    Application.put_env(:ash_enterprise, :display_time_zone, zone)
    on_exit(fn -> Application.put_env(:ash_enterprise, :display_time_zone, previous) end)
  end

  defp messages(view) do
    assert_push_event(view, "a2ui:messages", %{messages: messages}, 5_000)
    messages
  end

  defp value_at(messages, path) do
    Enum.find_value(messages, fn
      %{"updateDataModel" => %{"path" => ^path, "value" => value}} -> value
      _other -> nil
    end)
  end

  defp components(messages) do
    for message <- messages,
        %{"components" => components} <-
          [message["createSurface"], message["updateComponents"]],
        component <- components,
        do: component
  end

  # The surface's initial data model (createSurface carries it on v1.0).
  defp initial_query(messages) do
    Enum.find_value(messages, fn
      %{"createSurface" => %{"dataModel" => model}} -> model["query"]["table"]
      _other -> nil
    end)
  end

  # A query action on the event table, as the calendar sends it: the
  # `/query/table` state and the rows the LiveView pushes back.
  defp query!(view, state, extra) do
    render_hook(view, "a2ui:action", %{
      "version" => "v1.0",
      "action" => %{
        "name" => "query",
        "surfaceId" => "calendar",
        "sourceComponentId" => "calendar",
        "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
        "context" => Map.merge(%{"component" => "table", "query" => state}, extra)
      }
    })

    reply = messages(view)
    {value_at(reply, "/query/table"), value_at(reply, "/records/table")}
  end

  defp titles(rows), do: Enum.map(rows, & &1["title"])
  defp marks(query), do: Enum.map(query["window"]["marks"], & &1["date"])

  defp at(date, time, zone \\ "America/Toronto"),
    do: date |> DateTime.new!(time, zone, Tz.TimeZoneDatabase) |> DateTime.shift_zone!("Etc/UTC")

  test "the calendar shows the chosen month's and week's events on display-zone days",
       %{conn: conn, ctx: ctx} do
    in_zone("America/Toronto")

    event!(ctx, "Standup", 0, 15, starts_at: at(~D[2030-03-12], ~T[10:00:00]))
    # 21:30 on Friday the 15th in Toronto is already Saturday in UTC.
    event!(ctx, "Late Friday", 0, 60, starts_at: at(~D[2030-03-15], ~T[21:30:00]))
    event!(ctx, "Month review", 0, 60, starts_at: at(~D[2030-03-27], ~T[11:00:00]))
    event!(ctx, "April planning", 0, 60, starts_at: at(~D[2030-04-02], ~T[11:00:00]))

    {:ok, view, _html} = live(conn, "/app/calendar")
    bootstrap = messages(view)

    calendar = Enum.find(components(bootstrap), &(&1["component"] == "calendarView"))
    assert calendar["granularity"] == "month"
    assert calendar["granularities"] == ["month", "week"]
    assert Enum.any?(components(bootstrap), &(&1["component"] == "dataGrid"))

    # The first window is the display zone's current month.
    initial = initial_query(bootstrap)

    assert initial["window"]["anchor"] ==
             LocalTime.today() |> Date.beginning_of_month() |> to_string()

    # March 2030: its three events, marked on their Toronto days.
    {march, rows} = query!(view, initial, %{"anchor" => "2030-03-01"})
    assert titles(rows) == ["Standup", "Late Friday", "Month review"]
    assert {march["window"]["from"], march["window"]["to"]} == {"2030-03-01", "2030-03-31"}
    assert marks(march) == ["2030-03-12", "2030-03-15", "2030-03-27"]

    late = Enum.find(rows, &(&1["title"] == "Late Friday"))
    assert late["_calendar_start"] == "2030-03-15"

    # The next month holds only April's.
    {april, rows} = query!(view, march, %{"windowDelta" => 1})
    assert titles(rows) == ["April planning"]
    assert april["window"]["anchor"] == "2030-04-01"

    # Week: the week of the 12th (Monday the 11th to Sunday the 17th).
    {week, rows} = query!(view, march, %{"granularity" => "week", "anchor" => "2030-03-12"})

    assert {week["window"]["granularity"], week["window"]["from"], week["window"]["to"]} ==
             {"week", "2030-03-11", "2030-03-17"}

    assert titles(rows) == ["Standup", "Late Friday"]
    assert marks(week) == ["2030-03-12", "2030-03-15"]

    # The week after is empty; the size sticks.
    {next_week, rows} = query!(view, week, %{"windowDelta" => 1})
    assert next_week["window"]["granularity"] == "week"
    assert next_week["window"]["from"] == "2030-03-18"
    assert titles(rows) == []

    # Picking a day lists that day.
    {friday, rows} = query!(view, week, %{"date" => "2030-03-15"})
    assert friday["window"]["selected"] == "2030-03-15"
    assert titles(rows) == ["Late Friday"]
  end

  test "the presets switch the range and move the grid to it", %{conn: conn, ctx: ctx} do
    today = LocalTime.today()
    zone = LocalTime.zone()
    noon = fn days -> at(Date.add(today, days), ~T[12:00:00], zone) end

    events = [
      {"Today lunch", 0},
      {"Tomorrow lunch", 1},
      {"In five days", 5},
      {"In ten days", 10},
      {"In twenty days", 20}
    ]

    for {title, days} <- events, do: event!(ctx, title, 0, 30, starts_at: noon.(days))

    # Upcoming runs from now: today's lunch is in it until it is over.
    lunch_over? = DateTime.compare(DateTime.add(noon.(0), 30, :minute), DateTime.utc_now()) != :gt
    upcoming = if lunch_over?, do: [], else: ["Today lunch"]

    {:ok, view, _html} = live(conn, "/app/calendar")
    initial = initial_query(messages(view))

    # The grid is parked far from today, as if the user had navigated there.
    {away, rows} = query!(view, initial, %{"anchor" => "2031-06-01"})
    assert titles(rows) == []
    assert away["window"]["preset"] == ""

    for {preset, in_range} <- [
          {"today", ["Today lunch"]},
          {"tomorrow", ["Tomorrow lunch"]},
          {"this_week", ["Today lunch", "Tomorrow lunch", "In five days"]},
          {"upcoming", upcoming ++ ["Tomorrow lunch", "In five days", "In ten days"]}
        ] do
      {range, rows} = query!(view, Map.put(away, "preset", preset), %{"page" => 1})
      window = range["window"]

      # The grid moved to the window holding the preset's first day...
      first = if preset == "tomorrow", do: Date.add(today, 1), else: today
      assert window["anchor"] == first |> Date.beginning_of_month() |> to_string(), preset
      assert window["preset"] == preset
      assert window["selected"] == ""

      # ...and lists the preset's events that fall in it (a range that
      # runs past the month end continues in the next month).
      {from, to} = {Date.from_iso8601!(window["from"]), Date.from_iso8601!(window["to"])}

      visible =
        for {title, days} <- events,
            title in in_range,
            Date.compare(Date.add(today, days), from) != :lt,
            Date.compare(Date.add(today, days), to) != :gt,
            do: title

      assert titles(rows) == visible, preset
    end

    # Staying on a preset leaves the grid where the user takes it.
    {today_range, _rows} = query!(view, Map.put(away, "preset", "today"), %{"page" => 1})
    {moved, rows} = query!(view, today_range, %{"anchor" => "2031-06-01"})
    assert moved["window"]["anchor"] == "2031-06-01"
    assert titles(rows) == []

    # "All" shows every event of the window again.
    {all, rows} = query!(view, Map.put(moved, "preset", ""), %{"anchor" => to_string(today)})
    assert all["window"]["preset"] == ""
    assert "Today lunch" in titles(rows)
  end
end
