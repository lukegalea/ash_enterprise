defmodule AshEnterprise.Telemetry.Req do
  @moduledoc """
  A CLIENT span and `traceparent` propagation for every `Req` request, installed once
  for the whole node rather than at each call site.

  `AshEnterprise.Telemetry.setup/1` (`req: true`, the default) calls `install/0`, which
  adds this module to Req's default plugins (`Req.default_options/0`), so every
  `Req.new/1`, `Req.get/2`, `Req.post/2` and so on is traced with no change where the
  call is made. A call site that passes its own `:plugins` replaces the defaults and is
  not traced; one that already called `attach/2` is not traced twice.

  Each attempt is one span (`http.request.resend_count` on a retry), named after the
  method, with the attributes SigNoz's External API page groups by:

  | Attribute | Value |
  |---|---|
  | `http.request.method` | `GET`, `POST`, ... |
  | `server.address`, `server.port` | The host and port called |
  | `url.full` | The URL without credentials, query or fragment |
  | `url.scheme` | `http` or `https` |
  | `http.response.status_code` | The status; 400 and above sets the span's status to error |
  | `error.type` | The status code, or the exception module when the call failed |

  The query string is left out because it often carries keys and identifiers; the path
  is kept. The span's context is injected as `traceparent` (and `tracestate`) into the
  request, so a downstream service that reads it continues the trace; a `traceparent` the
  caller set itself is left as it is. Pass `trace_propagation: false` to a single request
  to leave the headers out, for a third party that should not see the trace id.
  """

  require OpenTelemetry.Tracer

  @private :ash_enterprise_telemetry
  @span :ash_enterprise_telemetry_span
  @propagate :ash_enterprise_telemetry_propagate

  @doc """
  Adds this plugin to Req's default options, so every `Req.new/1` attaches it.
  Idempotent; keeps any other defaults and plugins the application set.
  """
  @spec install() :: :ok
  def install do
    defaults = Application.get_env(:req, :default_options, [])
    plugins = Keyword.get(defaults, :plugins, [])

    if __MODULE__ in plugins do
      :ok
    else
      Application.put_env(
        :req,
        :default_options,
        Keyword.put(defaults, :plugins, plugins ++ [__MODULE__])
      )
    end
  end

  @doc "Removes the plugin from Req's default options."
  @spec uninstall() :: :ok
  def uninstall do
    defaults = Application.get_env(:req, :default_options, [])

    case Keyword.get(defaults, :plugins, []) -- [__MODULE__] do
      [] ->
        Application.put_env(:req, :default_options, Keyword.delete(defaults, :plugins))

      plugins ->
        Application.put_env(:req, :default_options, Keyword.put(defaults, :plugins, plugins))
    end
  end

  @doc """
  Attaches the span steps to one request. Idempotent, so a request built with the
  installed default and attached again by hand gets one span.

  `propagate_trace_headers: false` leaves the trace headers out of every request made
  with this client (the `trace_propagation: false` request option does it for one).
  """
  @spec attach(struct(), keyword()) :: struct()
  def attach(%{__struct__: Elixir.Req.Request} = request, opts \\ []) do
    request =
      case Keyword.fetch(opts, :propagate_trace_headers) do
        {:ok, propagate?} ->
          Elixir.Req.Request.put_private(request, @propagate, propagate? != false)

        :error ->
          request
      end

    if Elixir.Req.Request.get_private(request, @private) do
      request
    else
      request
      |> Elixir.Req.Request.put_private(@private, true)
      |> Elixir.Req.Request.register_options([:trace_propagation])
      |> Elixir.Req.Request.append_request_steps(ash_enterprise_telemetry: &start_span/1)
      |> Elixir.Req.Request.prepend_response_steps(ash_enterprise_telemetry: &end_span/1)
      |> Elixir.Req.Request.prepend_error_steps(ash_enterprise_telemetry: &end_error/1)
    end
  end

  # --- Steps: tracing never fails a request ------------------------------------------

  @doc false
  def start_span(request) do
    parent = OpenTelemetry.Ctx.get_current()
    method = method(request.method)

    span =
      OpenTelemetry.Tracer.start_span(parent, method, %{
        kind: :client,
        attributes: attributes(request, method)
      })

    request = Elixir.Req.Request.put_private(request, @span, span)

    default = Elixir.Req.Request.get_private(request, @propagate, true)

    # A `traceparent` the caller set itself is theirs to send.
    if Elixir.Req.Request.get_option(request, :trace_propagation, default) and
         Elixir.Req.Request.get_header(request, "traceparent") == [] do
      OpenTelemetry.Tracer.set_current_span(parent, span)
      |> :otel_propagator_text_map.inject_from([])
      |> Enum.reduce(request, fn {name, value}, acc ->
        Elixir.Req.Request.put_header(acc, to_string(name), to_string(value))
      end)
    else
      request
    end
  catch
    _kind, _reason -> request
  end

  @doc false
  def end_span({request, response}) do
    with span when span != nil <- Elixir.Req.Request.get_private(request, @span) do
      status = response.status
      OpenTelemetry.Span.set_attribute(span, :"http.response.status_code", status)

      if is_integer(status) and status >= 400 do
        OpenTelemetry.Span.set_attribute(span, :"error.type", Integer.to_string(status))
        OpenTelemetry.Span.set_status(span, OpenTelemetry.status(:error, ""))
      end

      OpenTelemetry.Span.end_span(span)
    end

    {Elixir.Req.Request.put_private(request, @span, nil), response}
  catch
    _kind, _reason -> {request, response}
  end

  @doc false
  def end_error({request, exception}) do
    with span when span != nil <- Elixir.Req.Request.get_private(request, @span) do
      OpenTelemetry.Span.set_attribute(span, :"error.type", inspect(exception.__struct__))

      OpenTelemetry.Span.set_status(
        span,
        OpenTelemetry.status(:error, safe_message(exception))
      )

      OpenTelemetry.Span.end_span(span)
    end

    {Elixir.Req.Request.put_private(request, @span, nil), exception}
  catch
    _kind, _reason -> {request, exception}
  end

  defp attributes(request, method) do
    uri = request.url

    %{
      "http.request.method": method,
      "server.address": uri.host || "",
      "server.port": port(uri),
      "url.full": %{uri | userinfo: nil, query: nil, fragment: nil} |> URI.to_string(),
      "url.scheme": uri.scheme || "http"
    }
    |> put_resend_count(Elixir.Req.Request.get_private(request, :req_retry_count, 0))
  end

  defp put_resend_count(attributes, count) when is_integer(count) and count > 0,
    do: Map.put(attributes, :"http.request.resend_count", count)

  defp put_resend_count(attributes, _count), do: attributes

  defp port(%URI{port: port}) when is_integer(port), do: port
  defp port(%URI{scheme: "https"}), do: 443
  defp port(_uri), do: 80

  defp method(method) when is_atom(method), do: method |> Atom.to_string() |> String.upcase()
  defp method(method) when is_binary(method), do: String.upcase(method)
  defp method(_method), do: "_OTHER"

  defp safe_message(%{__exception__: true} = exception) do
    exception |> Exception.message() |> String.slice(0, 256)
  rescue
    _error -> inspect(exception.__struct__)
  end

  defp safe_message(_other), do: ""
end
