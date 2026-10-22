defmodule AshEnterprise.Platform.LocalTime do
  @moduledoc """
  The operator's wall clock: which time zone "today" means, and how a time is
  written on a surface.

  Everything is stored in UTC. A person reading their day does not live in
  UTC, so the daily-loop surfaces (Today, Calendar, People) cut days and print
  times in one display zone: `config :ash_enterprise, :display_time_zone`
  (`DISPLAY_TIME_ZONE` at boot, see `config/runtime.exs`). One zone per
  deployment, because this is a single-operator daily driver; a per-user zone
  is a user attribute the day a second person uses it.

  Pure functions over the clock and the `tz` database — nothing here reads
  the database, so it is safe inside preparations and calculations.
  """

  @db Tz.TimeZoneDatabase

  @doc "The configured display zone (an IANA name)."
  @spec zone() :: String.t()
  def zone, do: Application.get_env(:ash_enterprise, :display_time_zone, "Etc/UTC")

  @doc "Now, in the display zone."
  @spec now() :: DateTime.t()
  def now, do: DateTime.now!(zone(), @db)

  @doc "Today's date in the display zone."
  @spec today() :: Date.t()
  def today, do: now() |> DateTime.to_date()

  @doc "A UTC instant shifted into the display zone."
  @spec to_local(DateTime.t()) :: DateTime.t()
  def to_local(%DateTime{} = datetime), do: DateTime.shift_zone!(datetime, zone(), @db)

  @doc """
  The UTC bounds `{from, to}` (from inclusive, to exclusive) of a named
  window, cut in the display zone:

    * `:today` / `:tomorrow` — that local calendar day;
    * `:this_week` — today and the six days after it (a rolling week, so the
      view is never empty on a Sunday evening);
    * `:upcoming` — from now to fourteen days out.
  """
  @spec window(:today | :tomorrow | :this_week | :upcoming) :: {DateTime.t(), DateTime.t()}
  def window(name), do: window(name, DateTime.utc_now())

  @doc """
  `window/1` as seen at the instant `at` rather than now: "today" is the
  display-zone day holding `at`, and `:upcoming` runs from `at`. What a
  calendar read as of a past instant (ADR 0049) cuts its window with.
  """
  @spec window(:today | :tomorrow | :this_week | :upcoming, DateTime.t()) ::
          {DateTime.t(), DateTime.t()}
  def window(:today, at), do: days(date(at), 1)
  def window(:tomorrow, at), do: days(Date.add(date(at), 1), 1)
  def window(:this_week, at), do: days(date(at), 7)
  def window(:upcoming, %DateTime{} = at), do: {at, DateTime.add(at, 14, :day)}

  @doc "The display-zone date an instant falls on."
  @spec date(DateTime.t()) :: Date.t()
  def date(%DateTime{} = at), do: at |> to_local() |> DateTime.to_date()

  @doc "The UTC bounds of `count` local days starting at `date`."
  @spec days(Date.t(), pos_integer()) :: {DateTime.t(), DateTime.t()}
  def days(%Date{} = date, count) do
    {midnight_utc(date), midnight_utc(Date.add(date, count))}
  end

  @doc "`09:30`, in the display zone."
  @spec time(DateTime.t() | nil) :: String.t()
  def time(nil), do: ""
  def time(%DateTime{} = datetime), do: datetime |> to_local() |> Calendar.strftime("%H:%M")

  @doc "`Mon 12 Oct`, in the display zone."
  @spec day(DateTime.t() | Date.t() | nil) :: String.t()
  def day(nil), do: ""
  def day(%Date{} = date), do: Calendar.strftime(date, "%a %-d %b")
  def day(%DateTime{} = datetime), do: datetime |> to_local() |> DateTime.to_date() |> day()

  @doc "`09:00–09:30`; an event crossing midnight carries the end's day."
  @spec range(DateTime.t(), DateTime.t()) :: String.t()
  def range(%DateTime{} = starts_at, %DateTime{} = ends_at) do
    if local_date(starts_at) == local_date(ends_at) do
      "#{time(starts_at)}–#{time(ends_at)}"
    else
      "#{time(starts_at)}–#{day(ends_at)} #{time(ends_at)}"
    end
  end

  @doc "`Mon 12 Oct · 09:00–09:30`."
  @spec span(DateTime.t(), DateTime.t()) :: String.t()
  def span(%DateTime{} = starts_at, %DateTime{} = ends_at),
    do: "#{day(starts_at)} · #{range(starts_at, ends_at)}"

  @doc "`Mon 12 Oct 09:30`, or `never` for nil."
  @spec stamp(DateTime.t() | nil) :: String.t()
  def stamp(nil), do: "never"
  def stamp(%DateTime{} = datetime), do: "#{day(datetime)} #{time(datetime)}"

  @doc """
  How long ago, coarsely: `just now`, `12 min ago`, `3 h ago`, `2 d ago`.
  Relative to the real clock; nil reads `never`.
  """
  @spec ago(DateTime.t() | nil) :: String.t()
  def ago(nil), do: "never"

  def ago(%DateTime{} = datetime) do
    seconds = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> "#{div(seconds, 60)} min ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)} h ago"
      true -> "#{div(seconds, 86_400)} d ago"
    end
  end

  defp local_date(datetime), do: datetime |> to_local() |> DateTime.to_date()

  # Local midnight as a UTC instant. A zone whose DST change skips midnight
  # (a gap) starts the day at the first instant after it; an ambiguous
  # midnight takes the earlier of the two.
  defp midnight_utc(date) do
    case DateTime.new(date, ~T[00:00:00], zone(), @db) do
      {:ok, datetime} -> datetime
      {:ambiguous, first, _second} -> first
      {:gap, _before, just_after} -> just_after
    end
    |> DateTime.shift_zone!("Etc/UTC", @db)
  end
end
