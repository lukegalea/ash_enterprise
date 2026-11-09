defmodule AshEnterprise.Telemetry.OtlpIngest do
  @moduledoc """
  A same-origin endpoint for browser spans, so the browser exports OTLP without a
  collector being exposed or CORS being opened.

      # in the Endpoint, before Plug.Parsers
      plug AshEnterprise.Telemetry.OtlpIngest

      config :ash_enterprise_telemetry, :browser_ingest,
        enabled: true,
        collector_url: "http://127.0.0.1:4318/v1/traces"

  Off unless configured: with no `:enabled` the plug passes every request through.

  ## The boundary this is

  A POST here is unauthenticated client input heading for the same store as
  server telemetry. It is held to these limits, each one rejecting or trimming
  before anything leaves the plug:

    * POST only (`405`), `application/json` with no content encoding (`415`).
    * The `Origin` must match the request's own host and port (`403`); a request
      with no `Origin` is rejected. `:allowed_origins` adds origins for a proxy
      that rewrites the host.
    * The body is capped at 256 KB (`413`), and at `:max_spans` spans (`413`).
    * A fixed-window rate limit per client address and one across all clients
      (`429`).
    * `ash.*`, `audit.*` and correlation attributes are removed from spans, events,
      links, instrumentation scopes and resources, because those are server-asserted
      facts. Spans with malformed ids are dropped. Names, status messages and
      attribute values are truncated, and attribute, event and link counts are capped.

  `service.name` stays client-supplied, so it cannot tell a server span from a
  forged one. The server-asserted `ash.*` attributes can.

  The accepted batch is forwarded to the collector in a supervised task, with a
  bounded number running at once and any beyond that dropped, and fed to
  `AshEnterprise.Telemetry.TraceSink` when the sink is running.

  ## Options

  From `config :ash_enterprise_telemetry, :browser_ingest`, overridden by plug options:

    * `:enabled` — off when false or absent
    * `:path` — request path, default `"/otel/v1/traces"`
    * `:collector_url` — OTLP/HTTP traces URL; no forwarding when absent
    * `:max_spans` — spans per batch, default 512
    * `:rate_limit` — requests per client per minute, default 600
    * `:global_rate_limit` — requests per minute across clients, default 6000
    * `:allowed_origins` — extra allowed origins, as `"https://host"` strings
    * `:trusted_attributes` — `{module, function, args}` given the conn, returning a
      map of server-asserted attributes to add to each span (a test key, for instance)
    * `:req_options` — extra options for the forwarding request
  """

  @behaviour Plug

  import Plug.Conn

  alias AshEnterprise.Telemetry.Attributes
  alias AshEnterprise.Telemetry.OtlpIngest.Limiter
  alias AshEnterprise.Telemetry.OtlpIngest.Tasks
  alias AshEnterprise.Telemetry.TraceSink

  require Logger

  @max_body_bytes 262_144
  @default_path "/otel/v1/traces"
  @default_max_spans 512
  @default_rate_limit 600
  @default_global_rate_limit 6_000

  @max_attributes 64
  @max_events 32
  @max_links 8
  @max_string_bytes 1_024

  @doc "Whether the ingest is enabled by configuration."
  @spec configured?() :: boolean()
  def configured? do
    :ash_enterprise_telemetry
    |> Application.get_env(:browser_ingest, [])
    |> Keyword.get(:enabled, false)
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    config =
      Application.get_env(:ash_enterprise_telemetry, :browser_ingest, []) |> Keyword.merge(opts)

    if Keyword.get(config, :enabled, false) and matches_path?(conn, config) do
      handle(conn, config)
    else
      conn
    end
  end

  defp matches_path?(conn, config) do
    conn.request_path == Keyword.get(config, :path, @default_path)
  end

  defp handle(conn, config) do
    with :ok <- check_method(conn),
         :ok <- check_content_type(conn),
         :ok <- check_origin(conn, config),
         :ok <- check_rate(conn, config),
         {:ok, body, conn} <- read_capped(conn),
         {:ok, payload} <- decode(body),
         :ok <- check_span_count(payload, config) do
      sanitized = sanitize(payload, trusted_attributes(conn, config))
      deliver(sanitized, config)
      respond(conn, 200, "{}")
    else
      {:reject, status} -> respond(conn, status, ~s({"error":"rejected"}))
      {:reject, status, conn} -> respond(conn, status, ~s({"error":"rejected"}))
    end
  end

  defp respond(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end

  # --- Checks --------------------------------------------------------------------

  defp check_method(%{method: "POST"}), do: :ok
  defp check_method(_conn), do: {:reject, 405}

  defp check_content_type(conn) do
    with ["application/json" <> _] <- get_req_header(conn, "content-type"),
         true <- get_req_header(conn, "content-encoding") in [[], ["identity"]] do
      :ok
    else
      _other -> {:reject, 415}
    end
  end

  defp check_origin(conn, config) do
    case get_req_header(conn, "origin") do
      [origin] ->
        if origin_allowed?(origin, conn, config), do: :ok, else: {:reject, 403}

      _missing ->
        {:reject, 403}
    end
  end

  defp origin_allowed?(origin, conn, config) do
    origin in Keyword.get(config, :allowed_origins, []) or
      authority(origin) == host_authority(conn)
  end

  # Host plus any non-default port. The scheme is ignored because a TLS-terminating
  # proxy puts http: on the conn while the browser sends https: in Origin.
  defp authority(origin) do
    case URI.parse(origin) do
      %URI{host: host, port: port} when is_binary(host) -> normalize_authority(host, port)
      _other -> nil
    end
  end

  defp host_authority(conn) do
    case get_req_header(conn, "host") do
      [host_header] ->
        case URI.parse("//" <> host_header) do
          %URI{host: host, port: port} when is_binary(host) -> normalize_authority(host, port)
          _other -> nil
        end

      _missing ->
        normalize_authority(conn.host, conn.port)
    end
  end

  defp normalize_authority(host, port) when port in [80, 443, nil], do: String.downcase(host)
  defp normalize_authority(host, port), do: "#{String.downcase(host)}:#{port}"

  defp check_rate(conn, config) do
    per_client = Keyword.get(config, :rate_limit, @default_rate_limit)
    global = Keyword.get(config, :global_rate_limit, @default_global_rate_limit)

    if Limiter.allow?({:client, conn.remote_ip}, per_client) and Limiter.allow?(:global, global) do
      :ok
    else
      {:reject, 429}
    end
  end

  defp read_capped(conn) do
    case read_body(conn, length: @max_body_bytes, read_length: @max_body_bytes) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:reject, 413, conn}
      {:error, _reason} -> {:reject, 400}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{"resourceSpans" => spans} = payload} when is_list(spans) -> {:ok, payload}
      _other -> {:reject, 400}
    end
  end

  defp check_span_count(payload, config) do
    max_spans = Keyword.get(config, :max_spans, @default_max_spans)

    if count_spans(payload) <= max_spans, do: :ok, else: {:reject, 413}
  end

  defp count_spans(%{"resourceSpans" => resource_spans}) do
    for %{"scopeSpans" => scope_spans} when is_list(scope_spans) <- resource_spans,
        %{"spans" => spans} when is_list(spans) <- scope_spans,
        reduce: 0 do
      acc -> acc + length(spans)
    end
  end

  # --- Sanitizing -----------------------------------------------------------------

  @doc false
  @spec sanitize(map(), map()) :: map()
  def sanitize(%{"resourceSpans" => resource_spans}, trusted) do
    %{
      "resourceSpans" =>
        resource_spans |> maps() |> Enum.map(&sanitize_resource_spans(&1, trusted))
    }
  end

  defp sanitize_resource_spans(resource_spans, trusted) do
    %{
      "resource" => sanitize_resource(resource_spans["resource"]),
      "scopeSpans" =>
        resource_spans["scopeSpans"] |> maps() |> Enum.map(&sanitize_scope(&1, trusted))
    }
  end

  defp sanitize_scope(scope_spans, trusted) do
    spans =
      scope_spans["spans"]
      |> maps()
      |> Enum.filter(&valid_ids?/1)
      |> Enum.map(&sanitize_span(&1, trusted))

    %{"scope" => sanitize_instrumentation_scope(scope_spans["scope"]), "spans" => spans}
  end

  defp sanitize_instrumentation_scope(%{} = scope) do
    scope
    |> Map.take(~w(name version))
    |> Map.new(fn {key, value} -> {key, truncate(value)} end)
    |> Map.put("attributes", clean(scope["attributes"]))
  end

  defp sanitize_instrumentation_scope(_other), do: %{"attributes" => []}

  defp maps(value), do: value |> list() |> Enum.filter(&is_map/1)

  defp sanitize_resource(%{} = resource), do: Map.update(resource, "attributes", [], &clean/1)
  defp sanitize_resource(_other), do: %{"attributes" => []}

  defp sanitize_span(span, trusted) do
    span
    |> Map.take(~w(traceId spanId parentSpanId name kind startTimeUnixNano endTimeUnixNano
      status))
    |> Map.update("name", "", &truncate/1)
    |> sanitize_status()
    |> Map.put("attributes", clean(span["attributes"]) ++ otlp_attributes(trusted))
    |> Map.put(
      "events",
      span["events"] |> list() |> Enum.take(@max_events) |> Enum.map(&sanitize_event/1)
    )
    |> Map.put(
      "links",
      span["links"] |> list() |> Enum.take(@max_links) |> Enum.map(&sanitize_link/1)
    )
    |> sanitize_parent()
  end

  defp sanitize_status(%{"status" => %{} = status} = span) do
    status = status |> Map.take(~w(code message)) |> truncate_status_message()
    Map.put(span, "status", status)
  end

  defp sanitize_status(span), do: Map.delete(span, "status")

  defp truncate_status_message(%{"message" => message} = status),
    do: Map.put(status, "message", truncate(message))

  defp truncate_status_message(status), do: status

  defp sanitize_parent(%{"parentSpanId" => parent} = span) when not is_binary(parent) do
    Map.delete(span, "parentSpanId")
  end

  defp sanitize_parent(span), do: span

  defp sanitize_event(%{} = event) do
    event
    |> Map.take(~w(name timeUnixNano))
    |> Map.update("name", "", &truncate/1)
    |> Map.put("attributes", clean(event["attributes"]))
  end

  defp sanitize_event(_other), do: %{"name" => "", "attributes" => []}

  defp sanitize_link(%{} = link) do
    link
    |> Map.take(~w(traceId spanId))
    |> Map.put("attributes", clean(link["attributes"]))
  end

  defp sanitize_link(_other), do: %{"attributes" => []}

  defp clean(attributes) do
    attributes
    |> list()
    |> Enum.flat_map(fn
      %{"key" => key, "value" => value} = attribute when is_binary(key) ->
        if Attributes.reserved?(key),
          do: [],
          else: [Map.put(attribute, "value", truncate_value(value))]

      _malformed ->
        []
    end)
    |> Enum.take(@max_attributes)
  end

  defp truncate_value(%{"stringValue" => value}) when is_binary(value),
    do: %{"stringValue" => truncate(value)}

  defp truncate_value(value), do: value

  defp truncate(value) when is_binary(value) do
    binary_part(value, 0, min(byte_size(value), @max_string_bytes))
  end

  defp truncate(_other), do: ""

  defp valid_ids?(%{"traceId" => trace_id, "spanId" => span_id})
       when is_binary(trace_id) and is_binary(span_id) do
    Regex.match?(~r/\A(?!0{32})[0-9a-f]{32}\z/, trace_id) and
      Regex.match?(~r/\A(?!0{16})[0-9a-f]{16}\z/, span_id)
  end

  defp valid_ids?(_span), do: false

  defp list(value) when is_list(value), do: value
  defp list(_other), do: []

  defp otlp_attributes(attributes) when map_size(attributes) == 0, do: []

  defp otlp_attributes(attributes) do
    for {key, value} <- attributes, do: %{"key" => key, "value" => %{"stringValue" => value}}
  end

  defp trusted_attributes(conn, config) do
    case config[:trusted_attributes] do
      {module, function, args} ->
        case apply(module, function, [conn | args]) do
          %{} = attributes -> Map.new(attributes, fn {k, v} -> {to_string(k), to_string(v)} end)
          _other -> %{}
        end

      nil ->
        %{}
    end
  rescue
    _exception -> %{}
  end

  # --- Delivery -------------------------------------------------------------------

  defp deliver(payload, config) do
    _ = TraceSink.ingest_otlp(payload)
    forward(payload, config)
  end

  defp forward(payload, config) do
    case config[:collector_url] do
      nil ->
        :ok

      url ->
        case Tasks.forward(url, payload, Keyword.get(config, :req_options, [])) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.debug("Dropped a browser span batch: #{inspect(reason)}")
            :ok
        end
    end
  end
end
