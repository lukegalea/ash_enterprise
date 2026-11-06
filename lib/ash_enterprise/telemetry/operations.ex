defmodule AshEnterprise.Telemetry.Operations do
  @moduledoc """
  Carries `ash_operations` telemetry onto the current OpenTelemetry span (ADR 0063).

  `AshOperations.Http` emits `[:operations, :request, :stop]` for every call and the webhook
  ingress emits `[:operations, :webhook, :received]` for every delivery. The generated action
  already has a span (`opentelemetry_ash`), so the HTTP detail nests under it: this handler
  sets a handful of **structural** attributes on whatever span is current, and nothing else.

  Structural means a name, a status or a count: provider, operation, effect, attempts, HTTP
  status, error reason, webhook outcome. Never a path, a query, an id, a header or a body (the
  path carries ids; the package's events carry none of them, and this module would drop them
  if they did). `attributes/2` is the whole of what it will set, and the tests pin it.

  `attach/0` is called from `AshEnterprise.Application.start/2`, once; attaching is idempotent.
  """

  @request [:operations, :request, :stop]
  @webhook [:operations, :webhook, :received]

  @request_keys ~w(provider operation effect attempts status reason)a
  @webhook_keys ~w(provider outcome status)a

  @handler_id "ash-enterprise-operations-span"

  @doc "Attach the span handler. Safe to call twice."
  @spec attach() :: :ok
  def attach do
    :telemetry.detach(@handler_id)
    :telemetry.attach_many(@handler_id, [@request, @webhook], &__MODULE__.handle_event/4, nil)
    :ok
  end

  @doc false
  def handle_event(event, _measurements, metadata, _config) do
    OpenTelemetry.Tracer.set_attributes(attributes(event, metadata))
  end

  @doc "The span attributes for an event: structural keys only, nil values dropped."
  @spec attributes([atom()], map()) :: [{String.t(), String.t() | integer() | atom()}]
  def attributes(@request, metadata), do: pick("operations", metadata, @request_keys)
  def attributes(@webhook, metadata), do: pick("operations.webhook", metadata, @webhook_keys)
  def attributes(_event, _metadata), do: []

  defp pick(prefix, metadata, keys) do
    for key <- keys, value = Map.get(metadata, key), value != nil do
      {"#{prefix}.#{key}", value}
    end
  end
end
