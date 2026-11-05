defmodule Battery.Execution.StartableKey do
  @moduledoc """
  The key of a process an agent may start: one on the allowlist, `keys/0`. Any other key
  fails to cast, so a request naming it is refused before anyone is asked to approve it,
  and the approved request is checked again where it runs.
  """

  use Ash.Type.NewType, subtype_of: :string

  @keys ["battery_follow_up"]

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(key, constraints) when is_binary(key) do
    if key in @keys, do: Ash.Type.cast_input(:string, key, constraints), else: :error
  end

  def cast_input(_value, _constraints), do: :error

  @doc "The process keys an agent may start."
  def keys, do: @keys
end
