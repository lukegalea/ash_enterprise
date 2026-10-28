defmodule AshEnterprise.Faults.Fault do
  @moduledoc "Raised by an armed `AshEnterprise.Faults.point/1` armed with `:raise`."

  defexception [:point]

  @impl true
  def message(%__MODULE__{point: point}), do: "fault point #{inspect(point)} fired"
end
