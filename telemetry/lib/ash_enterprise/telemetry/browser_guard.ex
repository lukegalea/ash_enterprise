defmodule AshEnterprise.Telemetry.BrowserGuard do
  @moduledoc false

  # The checks shared by the endpoints that take unauthenticated browser POSTs.
  # Each returns `:ok` or a `{:reject, status}` for a `with` chain.

  import Plug.Conn

  alias AshEnterprise.Telemetry.OtlpIngest.Limiter

  @spec check_method(Plug.Conn.t()) :: :ok | {:reject, 405}
  def check_method(%{method: "POST"}), do: :ok
  def check_method(_conn), do: {:reject, 405}

  @spec check_origin(Plug.Conn.t(), keyword()) :: :ok | {:reject, 403}
  def check_origin(conn, config) do
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

  @doc "Per-client and global limits, counted separately for each `scope`."
  @spec check_rate(Plug.Conn.t(), keyword(), atom(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:reject, 429}
  def check_rate(conn, config, scope, default_rate_limit, default_global_rate_limit) do
    per_client = Keyword.get(config, :rate_limit, default_rate_limit)
    global = Keyword.get(config, :global_rate_limit, default_global_rate_limit)

    if Limiter.allow?({scope, :client, client_key(conn, config)}, per_client) and
         Limiter.allow?({scope, :global}, global) do
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

  @spec read_capped(Plug.Conn.t(), pos_integer()) ::
          {:ok, binary(), Plug.Conn.t()} | {:reject, 413, Plug.Conn.t()} | {:reject, 400}
  def read_capped(conn, max_bytes) do
    case read_body(conn, length: max_bytes, read_length: max_bytes) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:reject, 413, conn}
      {:error, _reason} -> {:reject, 400}
    end
  end

  @spec respond(Plug.Conn.t(), pos_integer(), binary()) :: Plug.Conn.t()
  def respond(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end
end
