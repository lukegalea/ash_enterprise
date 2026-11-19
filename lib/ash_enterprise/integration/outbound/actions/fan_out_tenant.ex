defmodule AshEnterprise.Integration.Outbound.Actions.FanOutTenant do
  @moduledoc """
  The minute's fan-out for one tenant: each active endpoint whose cursor is behind the
  tenant's high-water mark runs `fan_out`. An endpoint with nothing new is not written to.
  One endpoint's failure is logged and does not stop the others; the next minute retries it.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query
  require Logger

  alias AshEnterprise.Audit.EventSource
  alias AshEnterprise.Integration.Outbound.Endpoint
  alias AshEnterprise.Platform.SystemActor

  @impl true
  def run(input, _opts, _context) do
    tenant = input.tenant
    high_water = EventSource.latest_sequence(tenant)

    Endpoint
    |> Ash.Query.filter(status == :active and cursor_sequence < ^high_water)
    |> Ash.read!(tenant: tenant, authorize?: false)
    |> Enum.each(&fan_out(&1, tenant))

    :ok
  end

  defp fan_out(endpoint, tenant) do
    endpoint
    |> Ash.Changeset.for_update(:fan_out, %{}, actor: SystemActor.oban(), tenant: tenant)
    |> Ash.update()
    |> case do
      {:ok, _endpoint} ->
        :ok

      {:error, error} ->
        Logger.warning(
          "outbound webhook fan-out failed for endpoint #{endpoint.id}: " <>
            Exception.message(Ash.Error.to_error_class(error))
        )
    end
  end
end
