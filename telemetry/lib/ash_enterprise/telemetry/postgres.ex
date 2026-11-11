defmodule AshEnterprise.Telemetry.Postgres do
  @moduledoc """
  Tags a Postgres transaction with its trace, so a session seen in `pg_stat_activity`
  can be traced back to its action.

      defmodule MyApp.Repo do
        use AshPostgres.Repo, otp_app: :my_app

        @impl true
        def on_transaction_begin(_reason) do
          AshEnterprise.Telemetry.Postgres.tag_transaction(__MODULE__)
        end
      end

  Enable it per environment, because it costs a round trip per transaction:

      config :ash_enterprise_telemetry, :pg_application_name?, true

  It sets `application_name` to the traceparent with `set_config(..., true)`, which
  lasts only for the transaction, so pooled connections carry no trace over to the
  next checkout. Reads outside a transaction are not covered. SQL comments are not
  used, because they defeat named prepared statements.
  """

  alias AshEnterprise.Telemetry.BrowserContext

  @doc "Sets `application_name` for the current transaction when enabled and in a span."
  @spec tag_transaction(module()) :: :ok
  def tag_transaction(repo) do
    if Application.get_env(:ash_enterprise_telemetry, :pg_application_name?, false) do
      case BrowserContext.current_traceparent() do
        nil -> :ok
        traceparent -> run(repo, traceparent)
      end
    else
      :ok
    end
  end

  defp run(repo, traceparent) do
    _ = repo.query("SELECT set_config('application_name', $1, true)", [traceparent])
    :ok
  rescue
    _exception -> :ok
  end
end
