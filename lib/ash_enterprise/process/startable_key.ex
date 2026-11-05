defmodule AshEnterprise.Process.StartableKey do
  @moduledoc """
  The key of a process an agent may start: a process key that is on the allowlist.

  The allowlist is `config :ash_enterprise, :agent_startable_processes, ["clinic.intake"]`,
  empty until a deployment names a process. It is code, reviewed like the other closed lists
  here (`AshEnterprise.Process.ActionInvoker`, `AshEnterprise.Platform.AutomationPrincipal`):
  a process is not startable by an agent because its diagram says so, or because an agent
  asks.

  A type rather than a check in the action, so a key that is not listed is refused where
  the request's arguments are cast, before any approval is asked for, and again where the
  approved request runs (`AshAgent.Invocation.Target`): a key taken off the list between the
  two stops the start.
  """

  use Ash.Type.NewType, subtype_of: :string

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(key, constraints) when is_binary(key) do
    if startable?(key), do: Ash.Type.cast_input(:string, key, constraints), else: :error
  end

  def cast_input(_value, _constraints), do: {:error, message: "must be a process key"}

  @doc "The process keys an agent may start."
  @spec keys() :: [String.t()]
  def keys, do: Application.get_env(:ash_enterprise, :agent_startable_processes, [])

  @doc "Whether an agent may start the process `key`."
  @spec startable?(String.t()) :: boolean()
  def startable?(key), do: key in keys()
end
