defmodule AshEnterprise.Canonical.Calculations.EventTime do
  @moduledoc """
  An event's time written for a person, in the display zone
  (`AshEnterprise.Platform.LocalTime`):

    * `format: :range` — `09:00–09:30`
    * `format: :span` — `Mon 12 Oct · 09:00–09:30`
    * `format: :day` — `Mon 12 Oct`

  Display-only: computed in Elixir from the stored UTC instants, so it is not
  sortable or filterable (sort and filter on `starts_at`).
  """

  use Ash.Resource.Calculation

  alias AshEnterprise.Platform.LocalTime

  @formats [:range, :span, :day]

  @impl true
  def init(opts) do
    if opts[:format] in @formats,
      do: {:ok, opts},
      else: {:error, "format must be one of #{inspect(@formats)}"}
  end

  @impl true
  def load(_query, _opts, _context), do: [:starts_at, :ends_at]

  @impl true
  def calculate(events, opts, _context) do
    {:ok, Enum.map(events, &format(&1, opts[:format]))}
  end

  defp format(%{starts_at: nil}, _format), do: nil
  defp format(event, :range), do: LocalTime.range(event.starts_at, event.ends_at)
  defp format(event, :span), do: LocalTime.span(event.starts_at, event.ends_at)
  defp format(event, :day), do: LocalTime.day(event.starts_at)
end
