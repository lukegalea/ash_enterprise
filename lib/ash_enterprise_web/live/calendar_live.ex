defmodule AshEnterpriseWeb.DailyLive.Calendar do
  @moduledoc """
  `/app/calendar` — a month or week grid of events, quick ranges, event
  detail (`AshEnterpriseWeb.A2ui.CalendarUI`), and the calendar through
  time (PROD-47).

  `CalendarEvent` is temporal (ADR 0049), so the page reads `?as_of=`
  (`AshA2ui.AsOf`, `time_travel: true`): every read of the surface runs at
  that instant, and the grid shows the events as they were known then. The
  surface is view-only while pinned. `?week=` names a week (any date in it,
  in the display zone): the grid opens on it, and the time scrubber above
  it carries that week's reschedules and cancellations as marks
  (`AshEnterprise.Canonical.CalendarHistory`). With `?as_of=` and no week,
  the week is the one holding the instant. Scrubbing keeps the week and
  moves the instant, so a week can be watched as it changed.

  Without either parameter the page is the live calendar it always was,
  opening on the month, and offers the week's time travel as a link.

  The history is read off the LiveView process, as the signed-in person,
  once the socket connects (iron law #01). Who is invited, and the people's
  names, are not temporal: they show as they are now, and the page says so.
  """

  use AshA2ui.LiveRenderer,
    ui: AshEnterpriseWeb.A2ui.CalendarUI,
    deep_link: true,
    time_travel: true,
    actor_fn: &__MODULE__.actor/1,
    tenant_fn: &__MODULE__.tenant/1,
    pubsub: [
      module: AshEnterprise.PubSub,
      topics: AshEnterprise.Surfaces.topics(AshEnterpriseWeb.A2ui.CalendarUI)
    ]

  use AshEnterpriseWeb, :verified_routes

  alias AshA2ui.{AsOf, TimeScrubber}
  alias AshEnterprise.Canonical.CalendarHistory
  alias AshEnterprise.Platform.LocalTime
  alias AshEnterprise.Security.ActorContext
  alias AshEnterpriseWeb.Layouts

  # How far back the scrubber reaches before the week, when no mark is older.
  @lead_days 7

  def actor(socket), do: socket.assigns[:current_user]
  def tenant(socket), do: ActorContext.tenant(socket.assigns[:current_user])

  @impl true
  def mount(params, session, socket) do
    week = week(params)

    {:ok, socket} =
      AshA2ui.LiveRenderer.mount(
        __ash_a2ui_config__(),
        window_params(params, week),
        session,
        socket
      )

    socket =
      assign(socket,
        week: week,
        marks: [],
        history_loaded?: false,
        to: DateTime.utc_now(),
        from: week && span_start(week, [])
      )

    {:ok, maybe_read_history(socket)}
  end

  @impl true
  def handle_async(:calendar_history, {:ok, history}, socket) do
    {:noreply,
     assign(socket,
       marks: history.marks,
       history_loaded?: true,
       from: span_start(socket.assigns.week, history.marks)
     )}
  end

  # A failed history read is a scrubber without marks, not a crashed page.
  def handle_async(:calendar_history, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, history_loaded?: true)}

  def handle_async(:ash_a2ui_surface, result, socket),
    do:
      AshA2ui.LiveRenderer.handle_async(__ash_a2ui_config__(), :ash_a2ui_surface, result, socket)

  # Navigation only: the position becomes an instant on the host's own
  # span, and the patch's `handle_params` rebuilds the surface at it.
  @impl true
  def handle_event("as_of_scrub", params, socket) do
    %{from: from, to: to, marks: marks, week: week} = socket.assigns
    at = TimeScrubber.instant(params, from, to, marks)
    {:noreply, push_patch(socket, to: week_path(week, at))}
  end

  def handle_event(event, params, socket)
      when event in ["a2ui:action", "a2ui:function_response", "a2ui:open_surface"],
      do: super(event, params, socket)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={assigns[:page]} width="max-w-7xl">
      <div :if={@week} class="space-y-3">
        <div
          :if={@ash_a2ui_as_of}
          id="calendar-as-of"
          role="status"
          class="rounded-base border-2 border-border bg-yellow px-4 py-2 text-sm text-on-vivid shadow-shadow"
        >
          Your calendar as it was known on {LocalTime.stamp(@ash_a2ui_as_of)}. Who was invited, and
          people's names, are shown as they are today. Nothing here can be changed.
        </div>
        <div class="flex flex-wrap items-baseline justify-between gap-2">
          <h2 id="calendar-week" class="font-heading text-lg">
            The week of {LocalTime.day(@week)}, through time
          </h2>
          <p
            :if={@history_loaded? and @marks == []}
            id="calendar-no-moves"
            class="text-sm text-foreground/70"
          >
            Nothing in this week has moved or been cancelled.
          </p>
        </div>
        <TimeScrubber.scrubber
          id="calendar-timeline"
          from={@from}
          to={@to}
          as_of={@ash_a2ui_as_of}
          marks={@marks}
          path={&week_path(@week, &1)}
          format={&LocalTime.stamp/1}
          label="This week through time"
        />
      </div>
      <div :if={is_nil(@week)} class="flex justify-end">
        <.link
          id="calendar-time-travel"
          navigate={week_path(CalendarHistory.week_start(LocalTime.today()), nil)}
          class="text-sm underline"
        >
          See this week through time
        </.link>
      </div>
      {AshA2ui.LiveRenderer.surface_container(assigns)}
    </Layouts.app>
    """
  end

  # --- the week ----------------------------------------------------------------

  # `?week=` (any date in it), else the week of `?as_of=`, else none: the
  # plain live calendar.
  defp week(params) do
    case {Date.from_iso8601(params["week"] || ""), AsOf.from_params(params)} do
      {{:ok, date}, _as_of} -> CalendarHistory.week_start(date)
      {_no_week, %DateTime{} = as_of} -> as_of |> LocalTime.date() |> CalendarHistory.week_start()
      {_no_week, nil} -> nil
    end
  end

  # The grid opens on the week, unless the URL already carries its window.
  defp window_params(params, nil), do: params

  defp window_params(params, week) when is_map(params) do
    if Map.has_key?(params, "q") do
      params
    else
      window = %{"granularity" => "week", "anchor" => Date.to_iso8601(week)}
      Map.put(params, "q", %{"table" => %{"window" => window}})
    end
  end

  defp window_params(params, _week), do: params

  defp maybe_read_history(%{assigns: %{week: nil}} = socket), do: socket

  defp maybe_read_history(socket) do
    if connected?(socket) do
      %{week: week, ash_a2ui_actor: actor, ash_a2ui_tenant: tenant} = socket.assigns
      opts = [actor: actor, tenant: tenant, at: socket.assigns.ash_a2ui_as_of]
      start_async(socket, :calendar_history, fn -> CalendarHistory.history(week, opts) end)
    else
      socket
    end
  end

  # From a week before the week starts, or an hour before the oldest mark.
  defp span_start(week, marks) do
    {week_from, _to} = LocalTime.days(week, 1)
    floor = DateTime.add(week_from, -@lead_days, :day)

    marks
    |> Enum.map(&DateTime.add(&1.at, -1, :hour))
    |> Enum.concat([floor])
    |> Enum.min(DateTime)
  end

  defp week_path(week, at),
    do: AsOf.put_param(~p"/app/calendar?#{[week: Date.to_iso8601(week)]}", at)
end
