defmodule AshEnterprise.Automation.Changes.FiringSeries do
  @moduledoc """
  `Incident.join` and `Incident.resolve_series`: adds the alert's series to the incident's
  `firing_series`, or takes it out. A `join` with no series changes nothing here.

  Not atomic, as `AshEnterprise.Automation.Changes.CountAlert` is not: the only writer
  (`AshEnterprise.Automation.Incidents`) holds a lock on the incident's key while it reads and
  writes, so the list it read is the list it writes over.
  """

  use Ash.Resource.Change

  @impl true
  def init(opts) do
    if opts[:op] in [:add, :remove],
      do: {:ok, opts},
      else: {:error, "op must be :add or :remove"}
  end

  @impl true
  def change(changeset, opts, _context) do
    case Ash.Changeset.get_argument(changeset, :series) do
      nil ->
        changeset

      series ->
        current = changeset.data.firing_series || []

        Ash.Changeset.change_attribute(
          changeset,
          :firing_series,
          apply_op(opts[:op], current, series)
        )
    end
  end

  defp apply_op(:add, current, series),
    do: if(series in current, do: current, else: current ++ [series])

  defp apply_op(:remove, current, series), do: List.delete(current, series)
end
