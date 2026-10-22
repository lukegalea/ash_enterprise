defmodule AshEnterprise.Canonical.Preparations.AgendaWindow do
  @moduledoc """
  Narrows a calendar read to one agenda window — today, tomorrow, this week or
  upcoming — cut in the operator's display zone
  (`AshEnterprise.Platform.LocalTime`), in start order.

  An event is in a window when it overlaps it, so a meeting that started
  before midnight and runs past it shows on both days. Cancelled events stay
  in: a cancellation is news on the day it would have happened, and the
  surfaces badge it rather than hide it.

  Computes the bounds from the read's instant only; never queries.

  ## As of an instant (ADR 0049)

  `CalendarEvent` is temporal. A read as of an instant
  (`Ash.Query.as_of/2`) cuts its window around that instant, not around
  the wall clock: "today, as of last Monday" is last Monday. Cut around the
  wall clock, every past agenda would read a window the events of then
  never reached, and come back empty. A read with no instant is a read now,
  and only then is the clock the instant. That is why this declares
  `temporal_safe?/1`.
  """

  use Ash.Resource.Preparation

  require Ash.Query

  alias AshEnterprise.Platform.LocalTime

  @windows [:today, :tomorrow, :this_week, :upcoming]

  @impl true
  def init(opts) do
    if opts[:window] in @windows do
      {:ok, opts}
    else
      {:error, "window must be one of #{inspect(@windows)}"}
    end
  end

  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def prepare(query, opts, _context) do
    {from, to} = LocalTime.window(opts[:window], instant(query))

    query
    |> Ash.Query.filter(starts_at < ^to and ends_at > ^from)
    |> Ash.Query.sort(starts_at: :asc)
  end

  # The instant the read is as of. `:now` and no instant at all are both a
  # read of the present.
  defp instant(%Ash.Query{as_of: %DateTime{} = as_of}), do: as_of
  defp instant(_now), do: DateTime.utc_now()
end
