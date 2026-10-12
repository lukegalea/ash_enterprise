defmodule AshEnterprise.Erasure.LiveScope.Aborted do
  @moduledoc """
  Carries the structural reason a `AshEnterprise.Erasure.LiveScope.run/2`
  function returned through `Ash.transact/3`, which turns every error into an
  Ash error class. `LiveScope.run/2` unwraps it again; nothing else sees it.
  """

  use Splode.Error, fields: [:reason], class: :unknown

  @impl true
  def message(%__MODULE__{}), do: "live-scope transaction rolled back"

  @doc "The reason inside an error `Ash.transact/3` returned, if it carried one."
  def unwrap(%__MODULE__{reason: reason}), do: {:ok, reason}

  def unwrap(%{errors: errors}) when is_list(errors),
    do: Enum.find_value(errors, :error, &with_reason/1)

  def unwrap(_error), do: :error

  defp with_reason(error) do
    case unwrap(error) do
      {:ok, _} = found -> found
      :error -> nil
    end
  end
end
