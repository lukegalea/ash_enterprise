defmodule AshEnterprise.Telemetry.SentryTunnel do
  @moduledoc """
  A same-origin tunnel for browser error reports, so the browser reaches Sentry or
  GlitchTip without CORS being opened or an ad blocker dropping the report. It is what
  `priv/js/sentry_browser.js` posts to by default.

      # in the Endpoint, before Plug.Parsers
      plug AshEnterprise.Telemetry.SentryTunnel

      config :ash_enterprise_telemetry, :browser_tunnel,
        enabled: true,
        dsns: [System.get_env("SENTRY_BROWSER_DSN")]

  Off unless configured: with no `:enabled` the plug passes every request through.

  ## The boundary this is

  A POST here is unauthenticated client input, held to the limits
  `AshEnterprise.Telemetry.OtlpIngest` applies:

    * POST only (`405`); `text/plain` or `application/x-sentry-envelope`, unencoded (`415`).
    * The `Origin` must match the request's own host and port (`403`).
    * The body is capped at 256 KB (`413`), with rate limits per client and overall (`429`).
    * The envelope's DSN must be on the allowlist (`403`). The destination is built from
      the configured DSN, so a client cannot aim the server at another host.
    * Only `event` items are forwarded, so attachments, replays and sessions stop here.
    * The event's `user` is removed, along with `ash.*`, `audit.*` and correlation keys
      in its tags and extra, because those are server-asserted facts. Request headers
      go, and URLs in the event and its breadcrumbs lose their query strings.

  A `trace_id` tag stays client-supplied: it joins a report to a trace, and a false one
  misleads no record.

  ## Options

  From `config :ash_enterprise_telemetry, :browser_tunnel`, overridden by plug options:

    * `:enabled` — off when false or absent
    * `:dsns` — the DSNs a browser may report to; with none, every envelope is refused
    * `:path` — request path, default `"/sentry/tunnel"`
    * `:rate_limit` — requests per client per minute, default 60
    * `:global_rate_limit` — requests per minute across clients, default 600
    * `:allowed_origins` — extra allowed origins, as `"https://host"` strings
    * `:client_key` — as for `AshEnterprise.Telemetry.OtlpIngest`; set it behind a proxy
    * `:req_options` — extra options for the forwarding request
  """

  @behaviour Plug

  import Plug.Conn

  alias AshEnterprise.Telemetry.Attributes
  alias AshEnterprise.Telemetry.BrowserGuard
  alias AshEnterprise.Telemetry.OtlpIngest.Tasks

  require Logger

  @default_path "/sentry/tunnel"
  @default_rate_limit 60
  @default_global_rate_limit 600
  @max_body_bytes 262_144
  @envelope_type "application/x-sentry-envelope"
  @url_keys ~w(url from to)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    config =
      Application.get_env(:ash_enterprise_telemetry, :browser_tunnel, []) |> Keyword.merge(opts)

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
    with :ok <- BrowserGuard.check_method(conn),
         :ok <- check_content_type(conn),
         :ok <- BrowserGuard.check_origin(conn, config),
         :ok <-
           BrowserGuard.check_rate(
             conn,
             config,
             :sentry,
             @default_rate_limit,
             @default_global_rate_limit
           ),
         {:ok, body, conn} <- BrowserGuard.read_capped(conn, @max_body_bytes),
         {:ok, header, items} <- parse(body),
         {:ok, dsn, url} <- destination(header, config),
         {:ok, events} <- scrub_events(items) do
      deliver(url, dsn, header, events, config)
      BrowserGuard.respond(conn, 200, "{}")
    else
      {:reject, status} -> BrowserGuard.respond(conn, status, ~s({"error":"rejected"}))
      {:reject, status, conn} -> BrowserGuard.respond(conn, status, ~s({"error":"rejected"}))
    end
  end

  defp check_content_type(conn) do
    with [type] <- get_req_header(conn, "content-type"),
         true <- String.starts_with?(type, ["text/plain", @envelope_type]),
         true <- get_req_header(conn, "content-encoding") in [[], ["identity"]] do
      :ok
    else
      _other -> {:reject, 415}
    end
  end

  # --- Envelope -------------------------------------------------------------------

  # A newline-separated header, then item header and payload pairs. A payload with a
  # `length` is measured in bytes, because it may itself contain newlines.
  defp parse(body) do
    {header_line, rest} = split_line(body)

    with {:ok, %{"dsn" => dsn} = header} when is_binary(dsn) <- Jason.decode(header_line),
         {:ok, items} <- parse_items(rest, []) do
      {:ok, header, items}
    else
      _malformed -> {:reject, 400}
    end
  end

  defp parse_items("", items), do: {:ok, Enum.reverse(items)}

  defp parse_items(rest, items) do
    {header_line, rest} = split_line(rest)

    with {:ok, %{"type" => type} = header} when is_binary(type) <- Jason.decode(header_line),
         {:ok, payload, rest} <- take_payload(header, rest) do
      parse_items(rest, [{type, payload} | items])
    else
      _malformed -> :error
    end
  end

  defp take_payload(%{"length" => length}, rest)
       when is_integer(length) and length >= 0 and byte_size(rest) >= length do
    tail = binary_part(rest, length, byte_size(rest) - length)
    {:ok, binary_part(rest, 0, length), String.replace_prefix(tail, "\n", "")}
  end

  defp take_payload(%{"length" => _invalid}, _rest), do: :error

  defp take_payload(_header, rest) do
    {payload, rest} = split_line(rest)
    {:ok, payload, rest}
  end

  defp split_line(binary) do
    case :binary.split(binary, "\n") do
      [line, rest] -> {line, rest}
      [line] -> {line, ""}
    end
  end

  # --- Destination ----------------------------------------------------------------

  defp destination(%{"dsn" => dsn}, config) do
    wanted = dsn_key(dsn)

    config
    |> Keyword.get(:dsns, [])
    |> Enum.find(&(is_binary(&1) and wanted != nil and dsn_key(&1) == wanted))
    |> case do
      nil -> {:reject, 403}
      allowed -> {:ok, allowed, envelope_url(allowed)}
    end
  end

  defp dsn_key(dsn) do
    case parsed_dsn(dsn) do
      nil ->
        nil

      {uri, public_key, prefix, project} ->
        {uri.scheme, uri.host, uri.port, public_key, prefix, project}
    end
  end

  defp parsed_dsn(dsn) do
    with %URI{scheme: scheme, host: host, userinfo: userinfo, path: path} = uri
         when is_binary(scheme) and is_binary(host) and is_binary(userinfo) and is_binary(path) <-
           URI.parse(dsn),
         [_ | _] = segments <- String.split(path, "/", trim: true) do
      [public_key | _secret] = String.split(userinfo, ":", parts: 2)
      {project, prefix} = List.pop_at(segments, -1)
      {uri, public_key, prefix, project}
    else
      _invalid -> nil
    end
  end

  defp envelope_url(dsn) do
    {uri, public_key, prefix, project} = parsed_dsn(dsn)

    URI.to_string(%URI{
      scheme: uri.scheme,
      host: uri.host,
      port: uri.port,
      path: "/" <> Enum.join(prefix ++ ["api", project, "envelope"], "/") <> "/",
      query: URI.encode_query(sentry_key: public_key)
    })
  end

  # --- Scrubbing ------------------------------------------------------------------

  defp scrub_events(items) do
    items
    |> Enum.filter(fn {type, _payload} -> type == "event" end)
    |> Enum.reduce_while({:ok, []}, fn {_type, payload}, {:ok, events} ->
      case Jason.decode(payload) do
        {:ok, %{} = event} -> {:cont, {:ok, [scrub_event(event) | events]}}
        _malformed -> {:halt, {:reject, 400}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      rejected -> rejected
    end
  end

  defp scrub_event(event) do
    event
    |> Map.delete("user")
    |> reject_reserved("tags")
    |> reject_reserved("extra")
    |> scrub_request()
    |> scrub_breadcrumbs()
  end

  defp reject_reserved(event, field) do
    case event do
      %{^field => %{} = map} ->
        Map.put(event, field, Map.reject(map, fn {key, _value} -> Attributes.reserved?(key) end))

      %{^field => _other} ->
        Map.delete(event, field)

      _absent ->
        event
    end
  end

  defp scrub_request(%{"request" => %{"url" => url}} = event) when is_binary(url) do
    Map.put(event, "request", %{"url" => strip_query(url)})
  end

  defp scrub_request(event), do: Map.delete(event, "request")

  defp scrub_breadcrumbs(%{"breadcrumbs" => crumbs} = event) when is_list(crumbs) do
    Map.put(event, "breadcrumbs", Enum.map(crumbs, &scrub_breadcrumb/1))
  end

  defp scrub_breadcrumbs(%{"breadcrumbs" => %{"values" => crumbs}} = event)
       when is_list(crumbs) do
    Map.put(event, "breadcrumbs", %{"values" => Enum.map(crumbs, &scrub_breadcrumb/1)})
  end

  defp scrub_breadcrumbs(event), do: Map.delete(event, "breadcrumbs")

  defp scrub_breadcrumb(%{"data" => %{} = data} = crumb) do
    data =
      Map.new(data, fn
        {key, value} when key in @url_keys and is_binary(value) -> {key, strip_query(value)}
        pair -> pair
      end)

    %{crumb | "data" => data}
  end

  defp scrub_breadcrumb(crumb), do: crumb

  defp strip_query(url), do: url |> String.split(["?", "#"], parts: 2) |> hd()

  # --- Delivery -------------------------------------------------------------------

  defp deliver(_url, _dsn, _header, [], _config), do: :ok

  defp deliver(url, dsn, header, events, config) do
    header = header |> Map.take(~w(event_id sent_at)) |> Map.put("dsn", dsn)

    case Tasks.forward_raw(
           url,
           encode(header, events),
           @envelope_type,
           config[:req_options] || []
         ) do
      :ok -> :ok
      {:error, reason} -> Logger.debug("Dropped a browser error report: #{inspect(reason)}")
    end
  end

  defp encode(header, events) do
    items =
      Enum.flat_map(events, fn event ->
        payload = Jason.encode!(event)
        [Jason.encode!(%{"type" => "event", "length" => byte_size(payload)}), payload]
      end)

    Enum.join([Jason.encode!(header) | items], "\n")
  end
end
