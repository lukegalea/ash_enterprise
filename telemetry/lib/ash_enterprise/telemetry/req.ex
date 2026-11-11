defmodule AshEnterprise.Telemetry.Req do
  @moduledoc """
  Instruments a `Req` client with a span and `traceparent` propagation.

      Req.new(base_url: url) |> AshEnterprise.Telemetry.Req.attach()

  `OpentelemetryReq` does not propagate unless told to, which silently breaks the
  trace at every outbound call; this turns propagation on.
  """

  @doc "Attaches `OpentelemetryReq` with `propagate_trace_headers: true` by default."
  @spec attach(struct(), keyword()) :: struct()
  def attach(%{__struct__: Elixir.Req.Request} = request, opts \\ []) do
    OpentelemetryReq.attach(request, Keyword.put_new(opts, :propagate_trace_headers, true))
  end
end
