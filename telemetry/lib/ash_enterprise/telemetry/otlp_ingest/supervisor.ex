defmodule AshEnterprise.Telemetry.OtlpIngest.Supervisor do
  @moduledoc false

  use Supervisor

  alias AshEnterprise.Telemetry.OtlpIngest.Limiter
  alias AshEnterprise.Telemetry.OtlpIngest.Tasks

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl Supervisor
  def init(_arg) do
    Supervisor.init([Limiter, Tasks], strategy: :one_for_one)
  end
end
