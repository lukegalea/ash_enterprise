defmodule AshEnterprise.Canonical.Preparations.AgendaWindow do
  @moduledoc """
  Narrows a calendar read to one agenda window — today, tomorrow, this week or
  upcoming — cut in the operator's display zone
  (`AshEnterprise.Platform.LocalTime`), in start order.

  An event is in a window when it overlaps it, so a meeting that started
  before midnight and runs past it shows on both days. Cancelled events stay
  in: a cancellation is news on the day it would have happened, and the
  surfaces badge it rather than hide it.

  Computes the bounds from the clock only; never queries.
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
  def prepare(query, opts, _context) do
    {from, to} = LocalTime.window(opts[:window])

    query
    |> Ash.Query.filter(starts_at < ^to and ends_at > ^from)
    |> Ash.Query.sort(starts_at: :asc)
  end
end
