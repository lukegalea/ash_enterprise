defmodule AshEnterprise.Telemetry.OperationsTest do
  # One global :telemetry handler, re-attached with different prefixes per test.
  use ExUnit.Case, async: false

  alias AshEnterprise.Telemetry.Operations
  alias OpenTelemetry.Tracer

  import AshEnterprise.Telemetry.TraceHelpers

  require OpenTelemetry.Tracer

  @call %{provider: :registry, operation: :activate, effect: :write, attempts: 2, status: 503}

  setup do
    on_exit(fn -> Operations.detach() end)
  end

  defp traced(name, fun) do
    key = test_key!()
    Tracer.with_span(name, do: fun.())
    span_named(key, name)
  end

  test "the attributes are structural only: no path, query, id, header or body" do
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

    assert Map.new(Operations.attributes(:request, metadata)) == %{
             "operations.provider" => :credential_registry,
             "operations.operation" => :activate,
             "operations.effect" => :write,
             "operations.attempts" => 2,
             "operations.status" => 503,
             "operations.reason" => :server_error
           }

    webhook =
      Operations.attributes(
        :webhook,
        %{provider: "credential-registry", outcome: :enqueued, status: 204, delivery: "d-1"}
      )

    assert Map.new(webhook) == %{
             "operations.webhook.provider" => "credential-registry",
             "operations.webhook.outcome" => :enqueued,
             "operations.webhook.status" => 204
           }

    assert Operations.attributes(:other, metadata) == []
  end

  test "with no options it handles ash_operations' default event names" do
    :ok = Operations.attach()

    span =
      traced("default.call", fn ->
        :telemetry.execute([:operations, :request, :stop], %{duration: 1}, @call)

        :telemetry.execute(
          [:operations, :webhook, :received],
          %{},
          %{provider: "registry", outcome: :enqueued, status: 204}
        )
      end)

    assert to_string(attr(span, "operations.operation")) == "activate"
    assert attr(span, "operations.attempts") == 2
    assert to_string(attr(span, "operations.webhook.outcome")) == "enqueued"
  end

  test "a host's own prefixes are the events it handles, under the same attribute names" do
    :ok =
      Operations.attach(
        request: [:my_app, :integration, :proxy],
        webhook: [:my_app, :integration, :webhook]
      )

    span =
      traced("prefixed.call", fn ->
        :telemetry.execute([:my_app, :integration, :proxy, :stop], %{duration: 1}, @call)

        :telemetry.execute(
          [:my_app, :integration, :webhook, :received],
          %{},
          %{provider: "registry", outcome: :duplicate, status: 200}
        )
      end)

    assert to_string(attr(span, "operations.provider")) == "registry"
    assert attr(span, "operations.status") == 503
    assert to_string(attr(span, "operations.webhook.outcome")) == "duplicate"

    # The default names are not handled once a host has chosen its own.
    ignored =
      traced("default.ignored", fn ->
        :telemetry.execute([:operations, :request, :stop], %{duration: 1}, @call)
      end)

    refute attr(ignored, "operations.operation")
  end

  test "attaching again replaces the handler rather than adding a second" do
    :ok = Operations.attach(request: [:first, :request])
    :ok = Operations.attach(request: [:second, :request])

    handlers =
      for event <- [[:first, :request, :stop], [:second, :request, :stop]],
          handler <- :telemetry.list_handlers(event),
          handler.id == "ash-enterprise-telemetry-operations-span",
          do: handler.event_name

    assert handlers == [[:second, :request, :stop]]
  end

  test "an event outside any span does not raise" do
    :ok = Operations.attach()
    :telemetry.execute([:operations, :request, :stop], %{duration: 1}, @call)
  end
end
