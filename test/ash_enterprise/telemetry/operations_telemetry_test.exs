defmodule AshEnterprise.Telemetry.OperationsTelemetryTest do
  @moduledoc """
  What this host does with `ash_operations` telemetry (ADR 0063): the metrics it declares and
  the span attributes it sets are structural only. The events and their hygiene belong to the
  package's own suite; this pins the host's use of them.
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

  test "the span handler sets no path, id or body attribute" do
    # What a careless event could carry, beside what the package emits.
    metadata = %{
      provider: :credential_registry,
      operation: :activate,
      effect: :write,
      attempts: 2,
      status: 503,
      reason: :server_error,
      path: "/v1/activations/stub-registry:abc",
      query: [{"subjectReference", "org:cred"}],
      body: %{"licenceNumber" => "L-1"},
      headers: %{"authorization" => ["Bearer secret"]},
      id: "act-1"
    }

    attributes = Operations.attributes([:operations, :request, :stop], metadata)

    assert Map.new(attributes) == %{
             "operations.provider" => :credential_registry,
             "operations.operation" => :activate,
             "operations.effect" => :write,
             "operations.attempts" => 2,
             "operations.status" => 503,
             "operations.reason" => :server_error
           }

    webhook =
      Operations.attributes(
        [:operations, :webhook, :received],
        %{provider: "credential-registry", outcome: :enqueued, status: 204, delivery: "d-1"}
      )

    assert Map.new(webhook) == %{
             "operations.webhook.provider" => "credential-registry",
             "operations.webhook.outcome" => :enqueued,
             "operations.webhook.status" => 204
           }

    assert Operations.attributes([:other, :event], metadata) == []
  end

  test "attaching is idempotent, and a handled event does not raise" do
    assert :ok = Operations.attach()
    assert :ok = Operations.attach()

    :telemetry.execute(
      [:operations, :request, :stop],
      %{duration: 1},
      %{provider: :credential_registry, operation: :list_activations, attempts: 1, status: 200}
    )
  end
end
