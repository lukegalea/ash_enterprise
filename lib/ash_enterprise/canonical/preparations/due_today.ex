defmodule AshEnterprise.Canonical.Preparations.DueToday do
  @moduledoc """
  Narrows a task read to today's: planned for today, or due before the end of
  today on the operator's display zone (`AshEnterprise.Platform.LocalTime`) —
  an overdue task is today's too. Soonest due first, undated last.

  Computes the bound from the clock only; never queries.
  """

  use Ash.Resource.Preparation

  require Ash.Query

  alias AshEnterprise.Platform.LocalTime

  @impl true
  def prepare(query, _opts, _context) do
    {_from, end_of_today} = LocalTime.days(LocalTime.today(), 1)

    query
    |> Ash.Query.filter(plan == :today or (not is_nil(due_at) and due_at < ^end_of_today))
    |> Ash.Query.sort(due_at: :asc_nils_last, inserted_at: :asc)
  end
end
