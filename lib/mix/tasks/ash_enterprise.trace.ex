defmodule Mix.Tasks.AshEnterprise.Trace do
  @shortdoc "Read recent OpenTelemetry traces from the in-BEAM dev sink"

  @moduledoc """
  Query the dev-loop trace ring (`AshEnterprise.Telemetry.TraceSink`) — the
  bounded in-BEAM store fed by the ordinary OpenTelemetry pipeline
  (docs/research/trace-storage-dev-to-prod.md §5).

      mix ash_enterprise.trace                       # last 5 traces, compact JSON
      mix ash_enterprise.trace --last 20 --pretty
      mix ash_enterprise.trace --trace-id 3f9c1e6a2b7c4d8e9a1b2c3d4e5f6071
      mix ash_enterprise.trace --correlation req-123 --explain
      mix ash_enterprise.trace --last 3 --explain --out /tmp/traces.json

  Selectors combine with `--explain` and the output options:

    * `--last N` — the last N *complete* traces, newest first (default 5)
    * `--trace-id ID` — one trace by id (integer or hex)
    * `--correlation ID` — traces carrying span attribute `ash.correlation_id`
    * `--explain` — per-trace reduction through `AshAgentTools.Trace.explain/2`
      (the agent-facing context-budget shape). If that package — `only: :dev`,
      `runtime: false` — does not ship the module or function yet, the task
      degrades to the raw span list with a note, rather than failing.
    * `--pretty` — indented JSON
    * `--out PATH` — write the JSON to a file instead of stdout

  This task reads the sink of the VM it boots. To inspect a *running* dev
  server, query the same API in that VM (Tidewave `project_eval`):

      AshEnterprise.Telemetry.TraceSink.last(5)

  The sink exists in :dev and :test only — prod never starts it (design: no
  dev sink in prod, env-gated supervision rather than a runtime flag).
  """

  use Mix.Task

  @requirements ["app.start"]

  @default_last 5

  @switches [
    last: :integer,
    trace_id: :string,
    correlation: :string,
    explain: :boolean,
    pretty: :boolean,
    out: :string
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)

    case invalid do
      [] -> :ok
      bad -> Mix.raise("Unknown option(s): #{inspect(bad)}")
    end

    unless AshEnterprise.Telemetry.TraceSink.running?() do
      Mix.raise("""
      The trace sink is not running. It starts only where
      `config :ash_enterprise, :trace_sink?` is true (config/dev.exs, config/test.exs).
      See docs/research/trace-storage-dev-to-prod.md §5.
      """)
    end

    traces = select(opts)
    payload = %{traces: Enum.map(traces, &render_trace(&1, opts))}

    json =
      if opts[:pretty] do
        Jason.encode!(payload, pretty: true)
      else
        Jason.encode!(payload)
      end

    write(json, opts)
  end

  # --- Selection --------------------------------------------------------------

  defp select(opts) do
    cond do
      id = opts[:trace_id] ->
        case AshEnterprise.Telemetry.TraceSink.trace(id) do
          nil -> Mix.raise("No complete trace with id #{id} in the ring")
          trace -> [trace]
        end

      correlation = opts[:correlation] ->
        AshEnterprise.Telemetry.TraceSink.by_correlation(correlation)

      true ->
        AshEnterprise.Telemetry.TraceSink.last(opts[:last] || @default_last)
    end
  end

  # --- Rendering ---------------------------------------------------------------

  defp render_trace(trace, opts) do
    if opts[:explain] do
      explain(trace)
    else
      raw_trace(trace)
    end
  end

  # The reduction is ash_agent_tools' job (pure, no ETS/OTel dep — design §5
  # layer split): `AshAgentTools.Trace.explain/2` takes a *list of span maps*.
  # The package is `only: :dev, runtime: false`, so the reference stays dynamic
  # — a compile-time call would warn in envs where the dep is absent — and any
  # failure degrades to the raw span list with a note rather than failing.
  @trace_explain_module "Elixir.AshAgentTools.Trace"

  defp explain(trace) do
    module = String.to_atom(@trace_explain_module)

    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        try do
          # Dot-call on a variable module rather than apply/3: same dynamic
          # dispatch (no compile-time warning where the dep is absent), and
          # credo --strict rightly prefers the call syntax when the arity is
          # known.
          report = module.explain(Enum.map(trace.spans, &explain_span/1), explain_opts())

          %{trace_id: hex(trace.trace_id, 32), explain: report}
        rescue
          e in [Protocol.UndefinedError, UndefinedFunctionError, ArgumentError] ->
            degrade(trace, e)
        end

      _ ->
        degrade(trace, :module_not_loaded)
    end
  end

  # SigNoz/Tempo deep-link, when the host configures one (design §5).
  defp explain_opts do
    case System.get_env("TRACE_BACKEND_URL") do
      nil -> []
      url -> [backend_url: url]
    end
  end

  # The sink's span shape -> the reduction's contract (parent_id, status map).
  defp explain_span(span) do
    %{
      trace_id: span.trace_id,
      span_id: span.span_id,
      parent_id: explain_parent(span.parent_span_id),
      name: span.name,
      kind: span.kind,
      status: %{code: span.status_code, message: span.status_message},
      attributes: span.attributes,
      start: span.start_time,
      end: span.end_time
    }
  end

  defp explain_parent(parent) when is_integer(parent) and parent > 0, do: parent
  defp explain_parent(_), do: nil

  defp degrade(trace, reason) do
    Map.put(raw_trace(trace), :explain_note, degrade_note(reason))
  end

  defp degrade_note(reason) do
    "AshAgentTools.Trace.explain/2 unavailable (#{inspect(reason)}); " <>
      "showing the raw span list instead"
  end

  defp raw_trace(trace) do
    %{
      trace_id: hex(trace.trace_id, 32),
      trace_id_int: trace.trace_id,
      duration_ms: trace.duration_ms,
      error?: trace.error?,
      correlation_ids: trace.correlation_ids,
      symbol_ids: trace.symbol_ids,
      root: span_view(trace.root),
      spans: Enum.map(trace.spans, &span_view/1)
    }
  end

  defp span_view(nil), do: nil

  defp span_view(span) do
    %{
      name: span.name,
      span_id: hex(span.span_id, 16),
      parent_span_id: (is_integer(span.parent_span_id) && hex(span.parent_span_id, 16)) || nil,
      kind: span.kind && to_string(span.kind),
      duration_ms: span_duration_ms(span),
      status: to_string(span.status_code),
      status_message: span.status_message,
      attributes: span.attributes
    }
  end

  defp span_duration_ms(span) do
    if is_integer(span.start_time) and is_integer(span.end_time) do
      System.convert_time_unit(span.end_time - span.start_time, :native, :millisecond)
    else
      nil
    end
  end

  defp hex(int, width) when is_integer(int) do
    int
    |> Integer.to_string(16)
    |> String.pad_leading(width, "0")
  end

  defp write(json, opts) do
    case opts[:out] do
      nil ->
        IO.puts(json)

      path ->
        File.write!(path, json <> "\n")
        Mix.shell().info("Wrote #{byte_size(json)} bytes to #{path}")
    end
  end
end
