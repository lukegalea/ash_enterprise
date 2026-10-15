defmodule AshEnterprise.Canonical.Calculations.LastActivity do
  @moduledoc "A conversation's newest message time, `Mon 12 Oct 09:30` on the operator's wall clock."

  use Ash.Resource.Calculation

  alias AshEnterprise.Platform.LocalTime

  @impl true
  def load(_query, _opts, _context), do: [:last_message_at]

  @impl true
  def calculate(records, _opts, _context) do
    {:ok, Enum.map(records, &LocalTime.stamp(&1.last_message_at))}
  end
end
