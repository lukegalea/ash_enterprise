defmodule Battery.Operations.Transport do
  @moduledoc """
  The battery registry's only HTTP client, over `AshOperations.Http`, answered by a
  `Req.Test` stub named after this module (`Battery.OperationsStub`). A wait between
  attempts is reported to the calling process as `{:slept, ms}` and never slept.

  `residency/0` says where the provider runs, for the disclosure gate: the application
  env's `:operations_residency`, `:sub_processor` unless a test sets another.
  """

  use AshOperations.Http

  @impl AshOperations.Http
  def config do
    test_pid = self()

    {:ok,
     %{
       base_url: "http://registry.battery.test",
       auth: {:bearer, "battery-synthetic-key"},
       req_options: [plug: {Req.Test, __MODULE__}],
       sleep: fn ms -> send(test_pid, {:slept, ms}) end,
       base_backoff_ms: 1,
       max_delay_ms: 5_000
     }}
  end

  @doc "Where the provider runs: `:in_cluster` or `:sub_processor`."
  @spec residency() :: :in_cluster | :sub_processor
  def residency,
    do: Application.get_env(:ash_enterprise_battery, :operations_residency, :sub_processor)

  # The error envelope's `code` and `requestId` only; its message is never read.
  @impl AshOperations.Http
  def classify(%{body: %{"code" => code} = body} = response) when is_binary(code) do
    %{
      reason: AshOperations.Http.status_reason(response.status),
      provider_code: code,
      request_id: body["requestId"]
    }
  end

  def classify(response), do: AshOperations.Http.by_status(response)
end
