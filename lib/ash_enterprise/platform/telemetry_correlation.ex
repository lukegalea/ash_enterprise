defmodule AshEnterprise.Platform.TelemetryCorrelation do
  @moduledoc """
  The telemetry package's view of `AshEnterprise.Platform.Correlation`, so spans and
  audit rows carry one id.

  `start_new/0` keeps an id the process already has. The package starts a new id for
  each LiveView event by default; here a LiveView keeps one id for its life, because
  the execution explorer's "everything recorded with this" joins a session's records
  by that id. A span still names its own action through its `ui.*` attributes.
  """

  @behaviour AshEnterprise.Telemetry.Correlation

  alias AshEnterprise.Platform.Correlation

  @impl true
  defdelegate current(), to: Correlation

  @impl true
  defdelegate put(id), to: Correlation

  @impl true
  defdelegate with_correlation(id, fun), to: Correlation

  @impl true
  def start_new, do: Correlation.id()
end
