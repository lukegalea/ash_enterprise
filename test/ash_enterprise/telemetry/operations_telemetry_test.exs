defmodule AshEnterprise.Telemetry.OperationsTelemetryTest do
  @moduledoc """
  What this host does with `ash_operations` telemetry (ADR 0063): the metrics it declares are
  structural only, and the span handler from the telemetry package is attached to the events
  this application's operations emit. The handler's own hygiene is pinned in the telemetry
  package's suite; this pins the host's use of it.
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.Telemetry.Operations

  @structural ~w(provider operation effect reason outcome status)a

  test "operation and webhook metrics are declared with structural tags only" do
    metrics =
      Enum.filter(AshEnterpriseWeb.Telemetry.metrics(), fn metric ->
        List.first(metric.event_name) == :operations
      end)

    assert length(metrics) >= 5
    assert [:operations, :request, :stop] in Enum.map(metrics, & &1.event_name)
    assert [:operations, :webhook, :received] in Enum.map(metrics, & &1.event_name)

    for metric <- metrics do
      assert metric.tags -- @structural == [],
             "#{inspect(metric.name)} tags #{inspect(metric.tags)}"
    end

    assert Enum.any?(
             AshEnterpriseWeb.Telemetry.metrics(),
             &(Enum.at(&1.name, 1) == :credentialing)
           )
  end

  test "the span handler is attached to the events this application's operations emit" do
    handler = &Operations.on_event/4

    for event <- [[:operations, :request, :stop], [:operations, :webhook, :received]] do
      assert Enum.any?(
               :telemetry.list_handlers(event),
               &(&1.event_name == event and &1.function == handler)
             ),
             "no span handler on #{inspect(event)}"
    end
  end

  test "the span attributes are structural only" do
    attributes =
      Operations.attributes(:request, %{
        provider: :credential_registry,
        operation: :activate,
        status: 503,
        path: "/v1/activations/stub-registry:abc",
        id: "act-1"
      })

    assert Map.new(attributes) == %{
             "operations.provider" => :credential_registry,
             "operations.operation" => :activate,
             "operations.status" => 503
           }
  end

  test "attaching is idempotent, and a handled event does not raise" do
    assert :ok =
             Operations.attach(request: [:operations, :request], webhook: [:operations, :webhook])

    assert :ok =
             Operations.attach(request: [:operations, :request], webhook: [:operations, :webhook])

    :telemetry.execute(
      [:operations, :request, :stop],
      %{duration: 1},
      %{provider: :credential_registry, operation: :list_activations, attempts: 1, status: 200}
    )
  end
end
