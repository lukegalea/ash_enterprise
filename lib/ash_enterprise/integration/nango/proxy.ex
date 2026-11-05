defmodule AshEnterprise.Integration.Nango.Proxy do
  @moduledoc """
  The one façade over Nango's HTTP API (Iron Law #20). Every outbound provider
  call goes through `request/2`; nothing else in the application talks to
  Nango or to a provider directly.

  A call is `METHOD {base_url}/proxy{path}` with

    * `Authorization: Bearer $NANGO_SECRET_KEY`
    * `Provider-Config-Key: <integration>`
    * `Connection-Id: <connection id>`

  plus `Idempotency-Key: <key>` when the request carries an `:idempotency_key`
  (the IETF HTTP API working group's `Idempotency-Key` header, which providers
  that deduplicate writes read). A governed invocation of an idempotent outside
  target passes its invocation key here, so a call repeated after a lost
  acknowledgement is taken once by the provider.

  Nango injects the provider's OAuth token and forwards to the provider's base
  URL, passing the provider's status and body back.

  ## Configuration (read at call time)

    * `NANGO_SECRET_KEY` — **environment only.** Never config, never logged,
      never in an error. Unset means `{:error, %ProxyError{reason: :not_configured}}`
      before any request is built.
    * `NANGO_BASE_URL` — defaults to `http://127.0.0.1:3003`.
    * `config :ash_enterprise, AshEnterprise.Integration.Nango, ...`:
      * `:base_url` — overrides `NANGO_BASE_URL`.
      * `:req_options` — merged into the `Req` request; tests use
        `plug: {Req.Test, AshEnterprise.Integration.Nango.Proxy}`.
      * `:max_attempts` (default 3), `:max_retry_delay_ms` (default 10_000),
        `:base_backoff_ms` (default 500), `:sleep` (a 1-arity fun; default
        `Process.sleep/1`).

  ## Retries

  A 429 (or a Google 403 rate-limit reason) is retried up to `:max_attempts`
  times, waiting for `Retry-After` (seconds or an HTTP date) when the provider
  sends it and exponential backoff otherwise. A wait longer than
  `:max_retry_delay_ms` is not slept: the call returns `:rate_limited` with
  `retry_after_ms` so an Oban job can snooze instead of holding a worker.
  5xx and transport failures are retried only for `:get`.

  ## Telemetry

  `[:ash_enterprise, :integration, :proxy, :start | :stop | :exception]`, with
  structural metadata only: integration, operation, method, attempts, status,
  reason. No path (it carries ids), no connection id, no body.
  """

  alias AshEnterprise.Integration.Nango.Classify
  alias AshEnterprise.Integration.ProxyError

  @default_base_url "http://127.0.0.1:3003"

  @type request :: %{
          required(:method) => :get | :post,
          required(:path) => String.t(),
          required(:provider_config_key) => String.t(),
          required(:connection_id) => String.t(),
          optional(:query) => [{String.t(), String.t()}],
          optional(:body) => map() | nil,
          optional(:idempotency_key) => String.t()
        }

  @type response :: %{status: pos_integer(), body: term()}

  @doc """
  Proxy one request through Nango.

  Options: `:profile` (`:http` | `:google` | `:slack`, default `:http`),
  `:operation` (an atom, for errors and telemetry only), `:numbers`
  (`:float`, the default, or `:decimal`: JSON numbers with a fraction decode
  as `Decimal`, so money never passes through a float).
  """
  @spec request(request(), keyword()) :: {:ok, response()} | {:error, ProxyError.t()}
  def request(%{method: method, path: path} = request, opts \\ []) do
    profile = Keyword.get(opts, :profile, :http)

    labels = %{
      integration: request.provider_config_key,
      operation: Keyword.get(opts, :operation),
      method: method
    }

    :telemetry.span([:ash_enterprise, :integration, :proxy], labels, fn ->
      {result, attempts} =
        case secret_key() do
          nil ->
            {{:error, error(%{reason: :not_configured, status: nil, provider_code: nil}, labels)},
             0}

          secret ->
            request
            |> build_req(secret, Keyword.get(opts, :numbers, :float))
            |> attempt(%{profile: profile, labels: labels, method: method, path: path}, 1)
        end

      {result, Map.merge(labels, stop_metadata(result, attempts))}
    end)
  end

  # --- request -----------------------------------------------------------------

  defp build_req(request, secret, numbers) do
    [
      base_url: base_url(),
      url: "/proxy" <> request.path,
      method: request.method,
      params: Map.get(request, :query, []),
      headers:
        [
          {"provider-config-key", request.provider_config_key},
          {"connection-id", request.connection_id}
        ] ++ idempotency_header(Map.get(request, :idempotency_key)),
      auth: {:bearer, secret},
      retry: false
    ]
    |> maybe_json(Map.get(request, :body))
    |> maybe_decimal_numbers(numbers)
    |> Req.new()
    |> Req.merge(config(:req_options, []))
  end

  defp idempotency_header(nil), do: []
  defp idempotency_header(key) when is_binary(key), do: [{"idempotency-key", key}]

  defp maybe_json(opts, nil), do: opts
  defp maybe_json(opts, body), do: Keyword.put(opts, :json, body)

  defp maybe_decimal_numbers(opts, :decimal),
    do: Keyword.put(opts, :decoders, json: &Jason.decode(&1, floats: :decimals))

  defp maybe_decimal_numbers(opts, _float), do: opts

  defp attempt(req, ctx, n) do
    case Req.request(req) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
        response = %{status: status, body: body, headers: headers}

        case Classify.classify(ctx.profile, response) do
          :ok -> {{:ok, %{status: status, body: body}}, n}
          {:error, fields} -> retry_or_fail(fields, retry_after_ms(headers), req, ctx, n)
        end

      {:error, _exception} ->
        # The exception is dropped on purpose: Req's carries the request.
        fields = %{reason: :transport, status: nil, provider_code: nil}
        retry_or_fail(fields, nil, req, ctx, n)
    end
  end

  defp retry_or_fail(fields, retry_after, req, ctx, n) do
    retryable? =
      fields.reason == :rate_limited or
        (fields.reason in [:server_error, :transport] and ctx.method == :get)

    delay = retry_after || backoff_ms(n)

    if retryable? and n < config(:max_attempts, 3) and
         delay <= config(:max_retry_delay_ms, 10_000) do
      sleep(delay)
      attempt(req, ctx, n + 1)
    else
      extra = if fields.reason == :rate_limited, do: %{retry_after_ms: retry_after}, else: %{}
      {{:error, error(Map.merge(fields, extra), ctx.labels)}, n}
    end
  end

  defp error(fields, labels) do
    ProxyError.exception(
      reason: fields.reason,
      status: fields.status,
      provider_code: fields.provider_code,
      retry_after_ms: Map.get(fields, :retry_after_ms),
      integration: labels.integration,
      operation: labels.operation
    )
  end

  defp stop_metadata({:ok, %{status: status}}, attempts),
    do: %{attempts: attempts, status: status, reason: nil}

  defp stop_metadata({:error, %ProxyError{} = e}, attempts),
    do: %{attempts: attempts, status: e.status, reason: e.reason}

  # --- Retry-After -------------------------------------------------------------

  @doc false
  def retry_after_ms(headers) do
    case Map.get(headers, "retry-after") do
      [value | _] -> parse_retry_after(String.trim(value))
      _ -> nil
    end
  end

  defp parse_retry_after(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 ->
        seconds * 1000

      _ ->
        case parse_http_date(value) do
          {:ok, at} -> max(DateTime.diff(at, DateTime.utc_now(), :millisecond), 0)
          :error -> nil
        end
    end
  end

  # IMF-fixdate, the only form RFC 9110 requires senders to use:
  # "Sun, 06 Nov 1994 08:49:37 GMT".
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  defp parse_http_date(value) do
    with [_, day, mon, year, time] <-
           Regex.run(~r/^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}:\d{2}:\d{2}) GMT$/, value),
         month when is_integer(month) <- Enum.find_index(@months, &(&1 == mon)),
         {:ok, date} <-
           Date.new(String.to_integer(year), month + 1, String.to_integer(day)),
         {:ok, time} <- Time.from_iso8601(time),
         {:ok, at} <- DateTime.new(date, time, "Etc/UTC") do
      {:ok, at}
    else
      _ -> :error
    end
  end

  defp backoff_ms(n), do: config(:base_backoff_ms, 500) * Integer.pow(2, n - 1)

  # --- config ------------------------------------------------------------------

  defp secret_key do
    case System.get_env("NANGO_SECRET_KEY") do
      value when value in [nil, ""] -> nil
      value -> value
    end
  end

  defp base_url do
    config(:base_url) || System.get_env("NANGO_BASE_URL") || @default_base_url
  end

  defp sleep(ms) do
    case config(:sleep) do
      fun when is_function(fun, 1) -> fun.(ms)
      _ -> Process.sleep(ms)
    end
  end

  defp config(key, default \\ nil) do
    :ash_enterprise
    |> Application.get_env(AshEnterprise.Integration.Nango, [])
    |> Keyword.get(key, default)
  end
end
