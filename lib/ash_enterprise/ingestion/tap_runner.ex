defmodule AshEnterprise.Ingestion.TapRunner do
  @moduledoc """
  Behaviour that executes one ingestion pipeline's tap (epic E1).

  The worker (`AshEnterprise.Ingestion.TapWorker`) owns parsing and landing; the
  runner owns only *how the tap process is invoked*. The default implementation
  shells out (`AshEnterprise.Ingestion.TapRunner.Exec`); tests inject a fake.
  Configure per deployment:

      config :ash_enterprise, AshEnterprise.Ingestion,
        tap_runner: AshEnterprise.Ingestion.TapRunner.Exec
  """

  @callback run(command :: String.t()) ::
              {:ok, output :: String.t()} | {:error, reason :: term()}

  @spec runner() :: module()
  def runner do
    Application.get_env(
      :ash_enterprise,
      AshEnterprise.Ingestion,
      []
    )
    |> Keyword.get(:tap_runner, AshEnterprise.Ingestion.TapRunner.Exec)
  end
end
