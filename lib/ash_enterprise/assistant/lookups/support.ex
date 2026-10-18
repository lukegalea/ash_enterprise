defmodule AshEnterprise.Assistant.Lookups.Support do
  @moduledoc """
  What every assistant read tool shares: the zone gate, the actor's read
  options, time windows a small model can name, record refs, and clipping.

  ## Windows

  One string argument, so a tool's schema stays small:

  | Value | Means (on the display zone's clock) |
  |---|---|
  | `today`, `tomorrow`, `yesterday` | that local day |
  | `this_week` | today and the six days after it |
  | `next_week` | Monday to Sunday of next week |
  | `monday` … `sunday` (or `mon` … `sun`) | the coming one: today when it is that day |
  | `next_7_days`, `next_30_days` | from now forward |
  | `last_7_days`, `last_30_days`, `last_90_days` | the days before now, now included |
  | `upcoming` | now to fourteen days out |
  | `2026-10-14` | that local day |
  | `2026-10-01..2026-10-14` | those local days, both ends included |

  ## Refs

  A record the model may cite is `"<surface>:<id>"`, the registry surface
  that shows it in detail (`AshEnterprise.Surfaces.record_surface/2`). The
  web resolves one at `/app/r/<surface>/<id>`, re-authorized as the reader;
  a ref is only ever a request.
  """

  alias AshEnterprise.Assistant.ZoneGate
  alias AshEnterprise.Platform.LocalTime
  alias AshEnterprise.Surfaces

  @named ~w(today tomorrow yesterday this_week next_week next_7_days next_30_days last_7_days last_30_days last_90_days upcoming)

  @weekdays ~w(monday tuesday wednesday thursday friday saturday sunday)

  @doc "The named windows, for argument descriptions and errors."
  @spec windows() :: [String.t()]
  def windows, do: @named

  @doc """
  Runs `fun.(opts)` as the actor in `context` if the zone gate admits the
  run's model target; otherwise the refusal, as a tool result the model
  reads. `fun` returns `{:ok, map}` or `{:error, term}`.
  """
  @spec gated(Ash.ActionInput.t(), map(), (keyword() -> {:ok, map()} | {:error, term()})) ::
          {:ok, map()} | {:error, term()}
  def gated(input, context, fun) do
    case ZoneGate.check_context(input.context) do
      :ok -> fun.(read_opts(context))
      {:error, reason} -> {:ok, %{"error" => ZoneGate.refusal(reason), "count" => 0}}
    end
  end

  @doc """
  The read options for the calling person: their actor and tenant, and
  `authorize?: true` stated rather than inherited, because these reads are
  the only thing standing between the model and someone else's rows.
  """
  @spec read_opts(map()) :: keyword()
  def read_opts(context) do
    context
    |> Ash.Context.to_opts()
    |> Keyword.take([:actor, :tenant, :tracer])
    |> Keyword.put(:authorize?, true)
  end

  @doc """
  The UTC bounds of a window string, `{:ok, {from, to}}`, `:none` for nil or
  blank, or `{:error, message}`.
  """
  @spec window(String.t() | nil) ::
          {:ok, {DateTime.t(), DateTime.t()}} | :none | {:error, String.t()}
  def window(nil), do: :none

  def window(value) when is_binary(value) do
    case days(value) do
      {:ok, first, last} -> {:ok, LocalTime.days(first, Date.diff(last, first) + 1)}
      :not_days -> from_now(name(value))
      other -> other
    end
  end

  @doc """
  The local days a window names, first and last included:
  `{:ok, first, last}`; `:not_days` for a window measured from now
  (`next_7_days`, `last_30_days`, `upcoming`, …); `:none` for nil or blank;
  or `{:error, message}`.

  A weekday is the coming one on the display zone's calendar, today when
  today is that day: "Monday" asked on a Sunday is tomorrow, asked on a
  Monday is today. The model names the day; this works out the date, which
  a small model gets wrong more often than it gets a weekday wrong.
  """
  @spec days(String.t() | nil) ::
          {:ok, Date.t(), Date.t()} | :not_days | :none | {:error, String.t()}
  def days(nil), do: :none

  def days(value) when is_binary(value) do
    case name(value) do
      "" -> :none
      name -> local_days(name, LocalTime.today())
    end
  end

  # Trimmed and lower-cased; words joined by underscores ("this week",
  # "next-week"), except in a date or a date range, whose hyphens are its own.
  defp name(value) do
    value = value |> String.trim() |> String.downcase()

    if value =~ ~r/^\d/,
      do: value,
      else: String.replace(value, ~r/[\s-]+/u, "_")
  end

  defp local_days("today", today), do: {:ok, today, today}
  defp local_days("tomorrow", today), do: one_day(Date.add(today, 1))
  defp local_days("yesterday", today), do: one_day(Date.add(today, -1))
  defp local_days("this_week", today), do: {:ok, today, Date.add(today, 6)}

  defp local_days("next_week", today) do
    monday = Date.add(today, 8 - Date.day_of_week(today))
    {:ok, monday, Date.add(monday, 6)}
  end

  defp local_days("this_" <> day, today) when day != "week", do: local_days(day, today)

  defp local_days(name, today) do
    cond do
      name in @named ->
        :not_days

      weekday = weekday(name) ->
        one_day(Date.add(today, rem(weekday - Date.day_of_week(today) + 7, 7)))

      true ->
        dates(name)
    end
  end

  defp one_day(date), do: {:ok, date, date}

  # 1 (Monday) to 7 (Sunday), from the full name or its first three letters.
  defp weekday(name) do
    Enum.find_value(Enum.with_index(@weekdays, 1), fn {day, n} ->
      if name == day or name == String.slice(day, 0, 3), do: n
    end)
  end

  defp dates(text) do
    case String.split(text, "..", parts: 2) do
      [day] ->
        with {:ok, date} <- date(day), do: one_day(date)

      [first, last] ->
        with {:ok, from} <- date(first),
             {:ok, to} <- date(last),
             :ok <- ordered(from, to) do
          {:ok, from, to}
        end
    end
  end

  defp from_now("next_7_days"), do: forward(7)
  defp from_now("next_30_days"), do: forward(30)
  defp from_now("upcoming"), do: forward(14)
  defp from_now("last_7_days"), do: back(7)
  defp from_now("last_30_days"), do: back(30)
  defp from_now("last_90_days"), do: back(90)

  defp forward(days) do
    now = DateTime.utc_now()
    {:ok, {now, DateTime.add(now, days, :day)}}
  end

  # The days before now, today included: "last 7 days" asked at noon covers
  # this morning too.
  defp back(days) do
    {_from, end_of_today} = LocalTime.days(LocalTime.today(), 1)
    {:ok, {DateTime.add(end_of_today, -days, :day), end_of_today}}
  end

  defp date(text) do
    case Date.from_iso8601(String.trim(text)) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, window_error(text)}
    end
  end

  defp ordered(from, to) do
    if Date.compare(from, to) == :gt,
      do: {:error, "the window's first day is after its last"},
      else: :ok
  end

  defp window_error(text) do
    "#{inspect(text)} is not a window. Use one of #{Enum.join(@named, ", ")}, " <>
      "a weekday (monday), a date (2026-10-14) or a date range (2026-10-01..2026-10-14)."
  end

  @doc "The window's label for a result: what the model is told it covered."
  @spec window_label({DateTime.t(), DateTime.t()} | nil) :: String.t() | nil
  def window_label(nil), do: nil

  def window_label({from, to}) do
    last = to |> DateTime.add(-1, :second)
    "#{LocalTime.stamp(from)} to #{LocalTime.stamp(last)}"
  end

  @doc "The ref of `record` on its registry surface, or nil when none shows it."
  @spec ref(module(), struct()) :: String.t() | nil
  def ref(resource, record) do
    case Surfaces.record_surface(resource, record) do
      %{key: key} -> "#{key}:#{record.id}"
      nil -> nil
    end
  end

  @doc "A `LIKE` pattern matching `term` anywhere, with its wildcards escaped."
  @spec like(String.t()) :: String.t()
  def like(term) do
    escaped =
      term
      |> String.trim()
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    "%" <> escaped <> "%"
  end

  @doc "Whether `haystack` (any of them) contains `needle`, ignoring case. Blank needles match."
  @spec matches?(String.t() | [String.t() | nil] | nil, String.t() | nil) :: boolean()
  def matches?(_haystack, needle) when needle in [nil, ""], do: true

  def matches?(haystacks, needle) when is_list(haystacks),
    do: Enum.any?(haystacks, &matches?(&1, needle))

  def matches?(haystack, needle) when is_binary(haystack),
    do: String.contains?(String.downcase(haystack), String.downcase(String.trim(needle)))

  def matches?(_haystack, _needle), do: false

  @doc "Clips `text` to `max` characters on one line; sealed-and-shredded values read as such."
  @spec clip(term(), pos_integer()) :: String.t() | nil
  def clip(nil, _max), do: nil
  def clip(%AshEnterprise.Erasure.Shredded{}, _max), do: "[erased]"

  def clip(text, max) when is_binary(text) do
    line = text |> String.replace(~r/\s+/u, " ") |> String.trim()

    if String.length(line) > max,
      do: String.slice(line, 0, max - 1) <> "…",
      else: line
  end

  def clip(other, max), do: other |> to_string() |> clip(max)

  @doc "A plain string for any value a calculation or sealed attribute may hold."
  @spec text(term()) :: String.t() | nil
  def text(nil), do: nil
  def text(%AshEnterprise.Erasure.Shredded{}), do: "[erased]"
  def text(%Ash.CiString{} = value), do: to_string(value)
  def text(value) when is_binary(value), do: value
  def text(value), do: to_string(value)

  @doc "A bounded limit from a model-supplied integer."
  @spec limit(integer() | nil, pos_integer(), pos_integer()) :: pos_integer()
  def limit(nil, default, _max), do: default
  def limit(n, _default, max) when is_integer(n) and n > max, do: max
  def limit(n, default, _max) when is_integer(n) and n < 1, do: default
  def limit(n, _default, _max) when is_integer(n), do: n

  @doc "A result row without its empty fields: fewer tokens for the model to read."
  @spec compact(map()) :: map()
  def compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end

  @doc "A tool's error result, for the model: never an exception message."
  @spec refused(String.t()) :: {:ok, map()}
  def refused(message), do: {:ok, %{"error" => message, "count" => 0}}
end
