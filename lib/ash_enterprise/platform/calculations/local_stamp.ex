defmodule AshEnterprise.Platform.Calculations.LocalStamp do
  @moduledoc """
  A timestamp attribute written on the operator's wall clock
  (`AshEnterprise.Platform.LocalTime`): `Mon 12 Oct 09:30`, or `never` when
  nil. `field:` names the attribute; `relative?: true` appends `· 12 min ago`.
  Display-only — sort and filter on the attribute itself.
  """

  use Ash.Resource.Calculation

  alias AshEnterprise.Platform.LocalTime

  @impl true
  def init(opts) do
    if is_atom(opts[:field]) and not is_nil(opts[:field]),
      do: {:ok, opts},
      else: {:error, "field is required"}
  end

  @impl true
  def load(_query, opts, _context), do: [opts[:field]]

  @impl true
  def calculate(records, opts, _context) do
    {:ok, Enum.map(records, &stamp(Map.get(&1, opts[:field]), opts[:relative?]))}
  end

  defp stamp(nil, _relative?), do: "never"
  defp stamp(%Date{} = date, _relative?), do: LocalTime.day(date)
  defp stamp(at, true), do: "#{LocalTime.stamp(at)} · #{LocalTime.ago(at)}"
  defp stamp(at, _relative?), do: LocalTime.stamp(at)
end
