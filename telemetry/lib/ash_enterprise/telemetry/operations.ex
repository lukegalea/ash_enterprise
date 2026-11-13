defmodule AshEnterprise.Telemetry.Operations do
  @moduledoc """
  Carries `ash_operations` telemetry onto the current OpenTelemetry span.

  `ash_operations` emits `request ++ [:stop]` for every provider call
  (`AshOperations.Http`, through `:telemetry.span/3`) and `webhook ++ [:received]` for
  every webhook delivery (`AshOperations.Webhook.Ingress`). `request` and `webhook` are
  the event prefixes: `[:operations, :request]` and `[:operations, :webhook]` unless a
  declaration sets `telemetry_prefix`. The generated action already has a span
  (`opentelemetry_ash`), so the HTTP detail nests under it: this handler sets a handful of
  **structural** attributes on whatever span is current, and nothing else.

  Structural means a name, a status or a count: provider, operation, effect, attempts, HTTP
  status, error reason, webhook outcome. Never a path, a query, an id, a header or a body (the
  path carries ids; the package's events carry none of them, and this module would drop them
  if they did). `attributes/2` is the whole of what it will set.

  | Attribute | Event |
  |---|---|
  | `operations.provider`, `operations.operation`, `operations.effect`, `operations.attempts`, `operations.status`, `operations.reason` | a provider call |
  | `operations.webhook.provider`, `operations.webhook.outcome`, `operations.webhook.status` | a webhook delivery |

  The attribute names do not change with the prefixes.

      # Application.start/2
      AshEnterprise.Telemetry.Operations.attach(
        request: [:my_app, :integration, :proxy],
        webhook: [:my_app, :integration, :webhook]
      )

  Call it once from the application start callback. Attaching again replaces the
  handler, so it is idempotent, and the prefixes of the latest call are the ones handled.
  """

  @default_request [:operations, :request]
  @default_webhook [:operations, :webhook]

  @request_keys ~w(provider operation effect attempts status reason)a
  @webhook_keys ~w(provider outcome status)a

  @handler_id "ash-enterprise-telemetry-operations-span"

  @typedoc "Which `ash_operations` event an attribute set is for."
  @type kind :: :request | :webhook

  @doc """
  Attach the span handler.

  Options:

    * `:request` — the event prefix of provider calls, as a declaration's
      `telemetry_prefix` sets it. The handler listens to `request ++ [:stop]`. Default
      `#{inspect(@default_request)}`.
    * `:webhook` — the event prefix of webhook deliveries, as the ingress's
      `telemetry_prefix:` sets it. The handler listens to `webhook ++ [:received]`.
      Default `#{inspect(@default_webhook)}`.
  """
  @spec attach(keyword()) :: :ok
  def attach(opts \\ []) do
    request = Keyword.get(opts, :request, @default_request) ++ [:stop]
    webhook = Keyword.get(opts, :webhook, @default_webhook) ++ [:received]

    :telemetry.detach(@handler_id)

    :ok =
      :telemetry.attach_many(
        @handler_id,
        [request, webhook],
        &__MODULE__.on_event/4,
        %{request => :request, webhook => :webhook}
      )
  end

  @doc "Detach the span handler. Safe to call when it is not attached."
  @spec detach() :: :ok
  def detach do
    :telemetry.detach(@handler_id)
    :ok
  end

  @doc false
  def on_event(event, _measurements, metadata, kinds) do
    case Map.fetch(kinds, event) do
      {:ok, kind} -> OpenTelemetry.Tracer.set_attributes(attributes(kind, metadata))
      :error -> :ok
    end
  end

  @doc "The span attributes for an event of `kind`: structural keys only, nil values dropped."
  @spec attributes(kind(), map()) :: [{String.t(), String.t() | integer() | atom()}]
  def attributes(:request, metadata), do: pick("operations", metadata, @request_keys)
  def attributes(:webhook, metadata), do: pick("operations.webhook", metadata, @webhook_keys)
  def attributes(_kind, _metadata), do: []

  defp pick(prefix, metadata, keys) do
    for key <- keys, value = Map.get(metadata, key), value != nil do
      {"#{prefix}.#{key}", value}
    end
  end
end
