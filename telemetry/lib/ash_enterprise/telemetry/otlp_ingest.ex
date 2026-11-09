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
    * A fixed-window rate limit per client and one across all clients (`429`). The
      client is the socket address, so behind a proxy every browser shares one bucket:
      set `:client_key` there.
    * `ash.*`, `audit.*` and correlation attributes are removed from spans, events,
      links, instrumentation scopes and resources, because those are server-asserted
      facts. Attribute values must be scalars, so a reserved key cannot arrive nested
      in a `kvlistValue`. Spans and links with malformed ids are dropped, as is a malformed
      parent id. Only the listed fields survive. Names, status messages and attribute
      values are truncated on a character boundary, oversized attribute keys are dropped,
      and attribute, event and link counts are capped.

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
    * `:client_key` — `{module, function, args}` given the conn, returning the term that
      identifies a client for `:rate_limit`; default the socket address. Behind a proxy,
      derive it from the address the proxy reports, taking only the hop your proxy
      appended: a client sets `X-Forwarded-For` to anything, and a value it controls gives
      it a fresh bucket per request. Returning `nil`, or raising, falls back to the
      socket address.
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
  alias AshEnterprise.Telemetry.Sanitize
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
  @max_key_bytes 128

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

    if Limiter.allow?({:client, client_key(conn, config)}, per_client) and
         Limiter.allow?(:global, global) do
      :ok
    else
      {:reject, 429}
    end
  end

  defp client_key(conn, config) do
    case config[:client_key] do
      {module, function, args} -> apply(module, function, [conn | args]) || conn.remote_ip
      nil -> conn.remote_ip
    end
  catch
    _kind, _reason -> conn.remote_ip
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

  defp sanitize_resource(%{} = resource), do: %{"attributes" => clean(resource["attributes"])}
  defp sanitize_resource(_other), do: %{"attributes" => []}

  defp sanitize_span(span, trusted) do
    span
    |> Map.take(~w(traceId spanId parentSpanId name kind startTimeUnixNano endTimeUnixNano
      status))
    |> Map.update("name", "", &truncate/1)
    |> sanitize_status()
    |> keep_if("kind", &kind?/1)
    |> keep_if("startTimeUnixNano", &timestamp?/1)
    |> keep_if("endTimeUnixNano", &timestamp?/1)
    |> keep_if("parentSpanId", &span_id?/1)
    |> Map.put("attributes", clean(span["attributes"]) ++ otlp_attributes(trusted))
    |> Map.put(
      "events",
      span["events"] |> maps() |> Enum.take(@max_events) |> Enum.map(&sanitize_event/1)
    )
    |> Map.put(
      "links",
      span["links"]
      |> maps()
      |> Enum.filter(&valid_ids?/1)
      |> Enum.take(@max_links)
      |> Enum.map(&sanitize_link/1)
    )
  end

  defp keep_if(map, key, valid?) do
    case map do
      %{^key => value} -> if valid?.(value), do: map, else: Map.delete(map, key)
      _absent -> map
    end
  end

  defp kind?(kind), do: is_integer(kind) or match?("SPAN_KIND_" <> _, kind)

  defp timestamp?(value) when is_integer(value), do: value >= 0
  defp timestamp?(value) when is_binary(value), do: Regex.match?(~r/\A\d{1,20}\z/, value)
  defp timestamp?(_value), do: false

  defp sanitize_status(%{"status" => %{} = status} = span) do
    status =
      status
      |> Map.take(~w(code message))
      |> keep_if("code", &(is_integer(&1) or match?("STATUS_CODE_" <> _, &1)))
      |> truncate_status_message()

    Map.put(span, "status", status)
  end

  defp sanitize_status(span), do: Map.delete(span, "status")

  defp truncate_status_message(%{"message" => message} = status),
    do: Map.put(status, "message", truncate(message))

  defp truncate_status_message(status), do: status

  defp sanitize_event(event) do
    event
    |> Map.take(~w(name timeUnixNano))
    |> Map.update("name", "", &truncate/1)
    |> keep_if("timeUnixNano", &timestamp?/1)
    |> Map.put("attributes", clean(event["attributes"]))
  end

  defp sanitize_link(link) do
    link
    |> Map.take(~w(traceId spanId))
    |> Map.put("attributes", clean(link["attributes"]))
  end

  defp clean(attributes) do
    attributes
    |> maps()
    |> Enum.flat_map(&clean_attribute/1)
    |> Enum.take(@max_attributes)
  end

  defp clean_attribute(%{"key" => key, "value" => value})
       when is_binary(key) and byte_size(key) <= @max_key_bytes do
    with false <- Attributes.reserved?(key),
         {:ok, scalar} <- scalar(value) do
      [%{"key" => key, "value" => scalar}]
    else
      _rejected -> []
    end
  end

  defp clean_attribute(_malformed), do: []

  # Exactly one scalar. An array or kvlist could carry a reserved key the check above
  # never sees.
  defp scalar(%{"stringValue" => value} = wrapper)
       when map_size(wrapper) == 1 and is_binary(value),
       do: {:ok, %{"stringValue" => truncate(value)}}

  defp scalar(%{"boolValue" => value} = wrapper)
       when map_size(wrapper) == 1 and is_boolean(value),
       do: {:ok, wrapper}

  defp scalar(%{"doubleValue" => value} = wrapper)
       when map_size(wrapper) == 1 and is_number(value),
       do: {:ok, wrapper}

  defp scalar(%{"intValue" => value} = wrapper)
       when map_size(wrapper) == 1 and is_integer(value),
       do: {:ok, wrapper}

  defp scalar(%{"intValue" => value} = wrapper)
       when map_size(wrapper) == 1 and is_binary(value) do
    if Regex.match?(~r/\A-?\d{1,20}\z/, value), do: {:ok, wrapper}, else: :error
  end

  defp scalar(_other), do: :error

  defp truncate(value) when is_binary(value), do: Sanitize.truncate(value, @max_string_bytes)
  defp truncate(_other), do: ""

  defp valid_ids?(%{"traceId" => trace_id, "spanId" => span_id}) do
    trace_id?(trace_id) and span_id?(span_id)
  end

  defp valid_ids?(_span), do: false

  defp trace_id?(id) when is_binary(id), do: Regex.match?(~r/\A(?!0{32})[0-9a-f]{32}\z/, id)
  defp trace_id?(_id), do: false

  defp span_id?(id) when is_binary(id), do: Regex.match?(~r/\A(?!0{16})[0-9a-f]{16}\z/, id)
  defp span_id?(_id), do: false

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
