defmodule AshEnterprise.Telemetry.TraceSink do
  @moduledoc """
  The bounded in-BEAM ring that holds recent traces for the dev loop.

  Design: `docs/research/trace-storage-dev-to-prod.md` §5 in the ash_enterprise
  repository. The sink is a
  *consumer of the span pipeline, not a competing pipeline* — spans arrive
  through the ordinary OpenTelemetry SDK, via
  `AshEnterprise.Telemetry.TraceSink.Exporter` hanging off
  `otel_simple_processor` (the batch processor's default 5s
  `scheduled_delay_ms` would kill the sub-second read-after-write the dev
  loop needs — design §1).

  Spans also arrive as OTLP JSON from the browser (`ingest_otlp/1`), normalised to
  the same span map.

  Five public ETS tables, all owned by this GenServer:

    * `__trace_ring__` — `:ordered_set` keyed on a `:counters` sequence
      number; the eviction ring. Oldest span = lowest key.
    * `__trace_spans__` — the span store, keyed `{trace_id, span_id}`, plus
      one `{trace_id, :trace}` record per trace holding its span ids,
      completeness and index keys.
    * `__trace_by_correlation__` / `__trace_by_symbol__` /
      `__trace_by_test_key__` — bag indexes from span attributes
      `ash.correlation_id` / `ash.symbol_id` / `ash.test_key` to trace ids.

  ## Invariants (each one tested)

    * **Trace-atomic eviction** — eviction never leaves a partial trace: it
      drops the *whole oldest trace* (all spans, ring entries, index entries)
      until the limits hold again. A lying debug tool is worse than none.
    * **`max_spans` backstop** — a hard ceiling on stored spans (default
      20_000; ash #2921 showed 3.85M spans/run is possible), enforced the
      same trace-atomic way.
    * **No partial-trace observation** — a trace becomes visible only once
      its root span has been exported (root end = commit point), and a read
      that catches an eviction mid-flight renders nothing rather than a
      trace with missing spans. A root is a span with no parent, or one whose
      parent is remote (stamped `ash.parent_remote`, for a server span adopted
      from a browser span that this VM may never see). A later parentless span
      takes over as the root.
    * **Late spans append** — a span arriving after its trace completed is added
      to that trace, not dropped.
    * **At-least-once delivery is harmless** — a span already stored is ignored
      by `{trace_id, span_id}`, so the ring and counters count each span once.
    * **No sink → backend backfill, ever** — the sink writes four ETS tables
      and nothing else.

  ## Bounds

      config :ash_enterprise_telemetry, :trace_sink, ring_size: 50, max_spans: 20_000

  Read live on every export batch, so tests can change the bounds without
  restarting anything; a browser suite raises them well above the default.

  The sink is dev/test-only: the supervision child is gated by
  `config :ash_enterprise_telemetry, :trace_sink?` (see
  `AshEnterprise.Telemetry.Application`), so prod never pays for it. VM-restart
  wipe is a feature — pre-recompile traces are lies.
  """

  use GenServer

  require Record

  @ring :__trace_ring__
  @spans :__trace_spans__
  @by_correlation :__trace_by_correlation__
  @by_symbol :__trace_by_symbol__
  @by_test_key :__trace_by_test_key__

  # The SDK's span record, straight from `opentelemetry/include/otel_span.hrl`.
  # `:otel_simple_processor` hands us tables of `#span{}` (one table per span on
  # the simple path, a scope-grouped table on the batch path — both read the
  # same way). The `#attributes{}` and `#status{}` records live in the SDK's
  # `src/`, which is not exported into _build — so instead of extracting them,
  # they are decoded positionally with size guards below (pinned SDK; a size
  # change fails closed to empty attributes / :unset status, never a crash).
  @span_record Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")

  @span_size length(@span_record) + 1

  @positions @span_record
             |> Enum.with_index(1)
             |> Map.new(fn {{field, _}, index} -> {field, index} end)

  @default_ring_size 50
  @default_max_spans 20_000

  # Counters: 1 = traces, 2 = spans, 3 = sequence. Shared through
  # :persistent_term because the read API bypasses the GenServer (readers hit
  # ETS directly) and stats must not queue behind the writer.
  @counters_key {__MODULE__, :counters}

  defstruct [:counters]

  # --- Supervision -----------------------------------------------------------

  @doc false
  def child_spec(_arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      type: :worker
    }
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- Write path (called by the Exporter) -----------------------------------

  @doc """
  Ingests ended spans — raw `:opentelemetry.span()` records, exactly as the
  exporter behaviour delivers them.

  Synchronous on purpose: the simple processor already blocks the ending
  process until export returns, and folding the write into that same
  synchronous window is what makes read-after-write hold the moment an Ash
  action returns. Returns `{:error, :not_running}` when the sink child is
  not up (prod, or an env that turned it off) so callers degrade quietly.
  """
  @spec export([tuple()]) :: :ok | {:error, :not_running}
  def export(spans) when is_list(spans) do
    if running?() do
      GenServer.call(__MODULE__, {:export, spans})
    else
      {:error, :not_running}
    end
  end

  @doc """
  Ingests an OTLP JSON payload, `%{"resourceSpans" => [...]}`, as browser spans
  arrive from `AshEnterprise.Telemetry.OtlpIngest`.

  Spans with malformed ids are skipped; the rest are stored. Returns
  `{:error, :not_running}` when the sink child is not up.
  """
  @spec ingest_otlp(map()) :: :ok | {:error, :not_running}
  def ingest_otlp(%{} = payload) do
    if running?() do
      GenServer.call(__MODULE__, {:ingest, otlp_span_maps(payload)})
    else
      {:error, :not_running}
    end
  end

  # --- Read path (direct ETS, no GenServer) ----------------------------------

  @doc "The last `n` *complete* traces, newest first."
  @spec last(pos_integer()) :: [map()]
  def last(n) when n > 0 do
    ring_trace_ids()
    |> Enum.take(n)
    |> Enum.map(&trace/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  One complete trace by id. Accepts the integer id or its hex spelling.
  Returns nil for unknown, evicted, or not-yet-complete traces — never a
  partial trace.
  """
  @spec trace(non_neg_integer() | String.t()) :: map() | nil
  def trace(trace_id) when is_integer(trace_id) and trace_id >= 0 do
    case :ets.lookup(@spans, {trace_id, :trace}) do
      [{_, record}] -> render(record)
      [] -> nil
    end
  end

  def trace(trace_id) when is_binary(trace_id) do
    hex = trace_id |> String.trim() |> String.trim_leading("0x") |> String.downcase()

    case Integer.parse(hex, 16) do
      {int, ""} -> trace(int)
      _ -> nil
    end
  end

  @doc "Complete traces carrying the given `ash.correlation_id`, newest first."
  @spec by_correlation(term()) :: [map()]
  def by_correlation(correlation_id), do: by_index(@by_correlation, correlation_id)

  @doc "Complete traces carrying the given `ash.symbol_id`, newest first."
  @spec by_symbol(term()) :: [map()]
  def by_symbol(symbol_id), do: by_index(@by_symbol, symbol_id)

  @doc "Complete traces carrying the given `ash.test_key`, newest first."
  @spec by_test_key(term()) :: [map()]
  def by_test_key(key), do: by_index(@by_test_key, key)

  @doc "Counts and current limits. Handy for the mix task's header line."
  @spec stats() :: %{
          traces: non_neg_integer(),
          spans: non_neg_integer(),
          ring_size: pos_integer(),
          max_spans: pos_integer()
        }
  def stats do
    counters = :persistent_term.get(@counters_key, nil)

    {traces, spans} =
      if counters do
        {:counters.get(counters, 1), :counters.get(counters, 2)}
      else
        {0, 0}
      end

    %{traces: traces, spans: spans, ring_size: ring_size(), max_spans: max_spans()}
  end

  @doc "Empties every table. Tests use this between scenarios."
  @spec clear() :: :ok
  def clear do
    if running?() do
      GenServer.call(__MODULE__, :clear)
    end

    :ok
  end

  @doc "Whether the sink process is up."
  @spec running?() :: boolean()
  def running? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  # --- GenServer callbacks ---------------------------------------------------

  @impl GenServer
  def init(_opts) do
    counters = :counters.new(3, [:write_concurrency])
    :persistent_term.put(@counters_key, counters)

    # `:named_table` + `:public`: readers are arbitrary processes (the mix
    # task, project_eval, tests) and must never queue behind the writer.
    :ets.new(@ring, [:named_table, :public, :ordered_set, read_concurrency: true])
    :ets.new(@spans, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@by_correlation, [:named_table, :public, :bag, read_concurrency: true])
    :ets.new(@by_symbol, [:named_table, :public, :bag, read_concurrency: true])
    :ets.new(@by_test_key, [:named_table, :public, :bag, read_concurrency: true])

    {:ok, %__MODULE__{counters: counters}}
  end

  @impl GenServer
  def handle_call({:export, spans}, _from, state) when is_list(spans) do
    spans
    |> Enum.flat_map(&span_tuple_to_map/1)
    |> Enum.each(&write_span(&1, state.counters))

    evict()
    {:reply, :ok, state}
  end

  def handle_call({:ingest, span_maps}, _from, state) when is_list(span_maps) do
    Enum.each(span_maps, &write_span(&1, state.counters))
    evict()
    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    for table <- [@ring, @spans, @by_correlation, @by_symbol, @by_test_key] do
      :ets.delete_all_objects(table)
    end

    # Rezero rather than recreate: the counters reference is shared via
    # :persistent_term with every reader.
    :counters.put(state.counters, 1, 0)
    :counters.put(state.counters, 2, 0)

    {:reply, :ok, state}
  end

  # --- Writing (single writer: this GenServer) --------------------------------

  defp span_tuple_to_map(span) when is_tuple(span) and tuple_size(span) == @span_size do
    [span_to_map(span)]
  end

  defp span_tuple_to_map(_other), do: []

  defp write_span(%{trace_id: trace_id, span_id: span_id} = span_map, counters) do
    # At-least-once delivery can repeat a span. First write wins: repeating it
    # must not add a ring entry or count it twice, or the eviction arithmetic
    # goes wrong.
    unless :ets.member(@spans, {trace_id, span_id}) do
      insert_new_span(span_map, counters)
    end
  end

  defp insert_new_span(span_map, counters) do
    # Single-writer (this GenServer), so add-then-get is race-free.
    seq =
      counters
      |> tap(&:counters.add(&1, 3, 1))
      |> :counters.get(3)

    span_map = Map.put(span_map, :seq, seq)
    trace_id = span_map.trace_id

    :ets.insert(@ring, {seq, trace_id})
    :ets.insert(@spans, {{trace_id, span_map.span_id}, span_map})

    record =
      case :ets.lookup(@spans, {trace_id, :trace}) do
        [{_, record}] -> record
        [] -> new_trace_record(trace_id)
      end

    new_trace? = record.span_count == 0
    record = add_span_to_record(record, span_map)

    :ets.insert(@spans, {{trace_id, :trace}, record})

    # Bags refuse duplicate identical tuples, so re-adding an id is a no-op.
    Enum.each(record.correlation_ids, fn id -> :ets.insert(@by_correlation, {id, trace_id}) end)
    Enum.each(record.symbol_ids, fn id -> :ets.insert(@by_symbol, {id, trace_id}) end)
    Enum.each(record.test_keys, fn key -> :ets.insert(@by_test_key, {key, trace_id}) end)

    :counters.add(counters, 2, 1)

    if new_trace? do
      :counters.add(counters, 1, 1)
    end
  end

  @correlation_keys ["ash.correlation_id", :"ash.correlation_id"]
  @symbol_keys ["ash.symbol_id", :"ash.symbol_id"]
  @test_key_keys ["ash.test_key", :"ash.test_key"]
  @parent_remote_keys ["ash.parent_remote", :"ash.parent_remote"]

  defp new_trace_record(trace_id) do
    %{
      trace_id: trace_id,
      spans: %{},
      root_span_id: nil,
      complete?: false,
      correlation_ids: MapSet.new(),
      symbol_ids: MapSet.new(),
      test_keys: MapSet.new(),
      span_count: 0
    }
  end

  defp add_span_to_record(record, span_map) do
    record = %{
      record
      | spans: Map.put(record.spans, span_map.span_id, span_map.seq),
        span_count: record.span_count + 1,
        correlation_ids:
          MapSet.union(record.correlation_ids, index_ids(span_map.attributes, @correlation_keys)),
        symbol_ids: MapSet.union(record.symbol_ids, index_ids(span_map.attributes, @symbol_keys)),
        test_keys: MapSet.union(record.test_keys, index_ids(span_map.attributes, @test_key_keys))
    }

    # A root's export is the commit point: the trace becomes observable when
    # this flips, never before. A parentless span is the true root and always
    # wins; a remote-parent span commits the trace only until one arrives.
    cond do
      root_span?(span_map) ->
        %{record | root_span_id: span_map.span_id, complete?: true}

      is_nil(record.root_span_id) and remote_parent?(span_map) ->
        %{record | root_span_id: span_map.span_id, complete?: true}

      true ->
        record
    end
  end

  defp remote_parent?(span_map) do
    Enum.any?(@parent_remote_keys, &(Map.get(span_map.attributes, &1) == true))
  end

  # `attributes` is always a map: `span_to_map/1` fails closed to `%{}` for
  # any SDK shape it does not recognise, so there is no non-map case to
  # catch here.
  defp index_ids(attributes, keys) do
    keys
    |> Enum.flat_map(fn key ->
      case Map.get(attributes, key) do
        nil -> []
        value -> [value]
      end
    end)
    |> MapSet.new()
  end

  # --- Rendering (no partial traces, ever) -------------------------------------

  defp render(record) do
    # Completeness is decided when the root span lands; re-check every span is
    # still present at read time. A concurrent trace-atomic eviction makes a
    # lookup return nil and we render *nothing* rather than a lie.
    {span_maps, complete?} =
      Enum.reduce(record.spans, {%{}, true}, fn {span_id, seq}, {acc, ok?} ->
        case :ets.lookup(@spans, {record.trace_id, span_id}) do
          [{_, span_map}] when span_map.seq == seq ->
            {Map.put(acc, span_id, span_map), ok?}

          _ ->
            {acc, false}
        end
      end)

    if complete? and record.complete? do
      spans = span_maps |> Map.values() |> Enum.sort_by(&{&1.start_time, &1.span_id})
      root = Enum.find(spans, &(&1.span_id == record.root_span_id))

      %{
        trace_id: record.trace_id,
        root: root,
        spans: spans,
        duration_ms: duration_ms(root),
        error?: Enum.any?(spans, &(&1.status_code == :error)),
        correlation_ids: MapSet.to_list(record.correlation_ids),
        symbol_ids: MapSet.to_list(record.symbol_ids),
        test_keys: MapSet.to_list(record.test_keys)
      }
    end
  end

  defp duration_ms(nil), do: nil

  defp duration_ms(root) do
    if is_integer(root.start_time) and is_integer(root.end_time) do
      System.convert_time_unit(root.end_time - root.start_time, :native, :millisecond)
    else
      nil
    end
  end

  defp by_index(table, id) do
    table
    |> :ets.lookup(id)
    |> Enum.map(fn {_id, trace_id} -> trace(trace_id) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.trace_id)
  end

  # Newest-first walk over the ring, deduplicated to trace ids. `unfold/2`
  # yields oldest→newest; reversing gives newest→oldest, and `Enum.uniq/1`
  # keeps the first (newest) occurrence of each trace.
  defp ring_trace_ids do
    unfold(:ets.last(@ring), [])
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp unfold(:"$end_of_table", acc), do: acc

  defp unfold(seq, acc) do
    case :ets.lookup(@ring, seq) do
      [{^seq, trace_id}] -> unfold(:ets.prev(@ring, seq), [trace_id | acc])
      [] -> unfold(:ets.prev(@ring, seq), acc)
    end
  end

  # --- Eviction (trace-atomic) --------------------------------------------------

  # Drop whole oldest traces until every limit holds. Never a partial trace:
  # `drop_trace/1` removes all spans, ring entries and index entries of one
  # trace, or nothing. Runs after each export batch; bounds are read live.
  defp evict do
    if over_limit?() do
      case :ets.first(@ring) do
        :"$end_of_table" -> :ok
        oldest_seq -> evict_oldest(oldest_seq)
      end
    end
  end

  defp over_limit? do
    counters = :persistent_term.get(@counters_key, nil)

    if counters do
      :counters.get(counters, 1) > ring_size() or :counters.get(counters, 2) > max_spans()
    else
      false
    end
  end

  defp evict_oldest(oldest_seq) do
    [{^oldest_seq, trace_id}] = :ets.lookup(@ring, oldest_seq)
    drop_trace(trace_id)

    if over_limit?() do
      case :ets.first(@ring) do
        :"$end_of_table" -> :ok
        next -> evict_oldest(next)
      end
    end
  end

  defp drop_trace(trace_id) do
    case :ets.lookup(@spans, {trace_id, :trace}) do
      [] ->
        # A ring entry whose trace record is already gone (defensive; cannot
        # happen with a single writer): drop the stale entries so walks advance.
        :ets.match_delete(@ring, {:_, trace_id})

      [{_, record}] ->
        Enum.each(record.spans, fn {span_id, seq} ->
          :ets.delete(@ring, seq)
          :ets.delete(@spans, {trace_id, span_id})
        end)

        Enum.each(record.correlation_ids, fn id ->
          :ets.delete_object(@by_correlation, {id, trace_id})
        end)

        Enum.each(record.symbol_ids, fn id ->
          :ets.delete_object(@by_symbol, {id, trace_id})
        end)

        Enum.each(record.test_keys, fn key ->
          :ets.delete_object(@by_test_key, {key, trace_id})
        end)

        :ets.delete(@spans, {trace_id, :trace})

        counters = :persistent_term.get(@counters_key, nil)

        if counters do
          :counters.add(counters, 1, -1)
          :counters.add(counters, 2, -record.span_count)
        end
    end
  end

  # --- Config (read live, so tests can shrink bounds without a restart) ---------

  defp config do
    Application.get_env(:ash_enterprise_telemetry, :trace_sink, [])
  end

  defp ring_size, do: Keyword.get(config(), :ring_size, @default_ring_size)
  defp max_spans, do: Keyword.get(config(), :max_spans, @default_max_spans)

  # --- SDK records → plain maps ---------------------------------------------------

  defp span_to_map(span) do
    attributes = attribute_map(elem(span, pos(:attributes)))

    # #status{code, message} — positionally, with a size guard.
    status = elem(span, pos(:status))

    {status_code, status_message} =
      if is_tuple(status) and tuple_size(status) == 3 do
        {elem(status, 1), elem(status, 2)}
      else
        {:unset, nil}
      end

    %{
      trace_id: elem(span, pos(:trace_id)),
      span_id: elem(span, pos(:span_id)),
      parent_span_id: elem(span, pos(:parent_span_id)),
      name: name(elem(span, pos(:name))),
      kind: elem(span, pos(:kind)),
      start_time: elem(span, pos(:start_time)),
      end_time: elem(span, pos(:end_time)),
      attributes: attributes,
      events: events(elem(span, pos(:events))),
      links: links(elem(span, pos(:links))),
      status_code: status_code,
      status_message: status_message,
      seq: nil
    }
  end

  # #attributes{count_limit, value_length_limit, dropped, map} — the map is the last
  # field. Unknown shapes fail closed to an empty map.
  defp attribute_map(attrs) when is_tuple(attrs) and tuple_size(attrs) == 5 do
    :otel_attributes.map(attrs)
  rescue
    _ -> %{}
  end

  defp attribute_map(_attrs), do: %{}

  # #events{} holds #event{system_time_native, name, attributes}, newest first. Unknown
  # shapes fail closed to no events.
  defp events(events) do
    events
    |> :otel_events.list()
    |> Enum.flat_map(fn
      {:event, _time, name, attrs} -> [%{name: name(name), attributes: attribute_map(attrs)}]
      _other -> []
    end)
    |> Enum.reverse()
  rescue
    _ -> []
  end

  # #links{} holds #link{trace_id, span_id, attributes, tracestate}. Unknown shapes
  # fail closed to no links.
  defp links(links) do
    links
    |> :otel_links.list()
    |> Enum.flat_map(fn
      {:link, trace_id, span_id, attrs, _tracestate} ->
        [%{trace_id: trace_id, span_id: span_id, attributes: attribute_map(attrs)}]

      _other ->
        []
    end)
  rescue
    _ -> []
  end

  defp name(name) when is_atom(name), do: Atom.to_string(name)
  defp name(name) when is_binary(name), do: name
  defp name(other), do: inspect(other)

  # The root span is the one with no parent (nil, 0, or the SDK's :undefined).
  def root_span?(span_map) do
    parent = span_map.parent_span_id
    is_nil(parent) or parent == 0 or parent == :undefined
  end

  defp pos(field), do: Map.fetch!(@positions, field)

  # --- OTLP JSON -> plain maps ----------------------------------------------------

  defp otlp_span_maps(payload) do
    for %{} = resource_spans <- list_at(payload, "resourceSpans"),
        %{} = scope_spans <- list_at(resource_spans, "scopeSpans"),
        %{} = span <- list_at(scope_spans, "spans"),
        map = otlp_span_map(span),
        do: map
  end

  defp list_at(map, key) do
    case Map.get(map, key) do
      list when is_list(list) -> list
      _other -> []
    end
  end

  defp otlp_span_map(span) do
    with trace_id when is_integer(trace_id) <- hex_id(span["traceId"], 32),
         span_id when is_integer(span_id) <- hex_id(span["spanId"], 16) do
      %{
        trace_id: trace_id,
        span_id: span_id,
        parent_span_id: hex_id(span["parentSpanId"], 16),
        name: name(span["name"] || ""),
        kind: otlp_kind(span["kind"]),
        start_time: native_time(span["startTimeUnixNano"]),
        end_time: native_time(span["endTimeUnixNano"]),
        attributes: otlp_attributes(span["attributes"]),
        events: Enum.map(list_at(span, "events"), &otlp_event/1),
        links: Enum.flat_map(list_at(span, "links"), &otlp_link/1),
        status_code: otlp_status_code(span["status"]),
        status_message: otlp_status_message(span["status"]),
        seq: nil
      }
    else
      _malformed -> nil
    end
  end

  defp hex_id(value, length) when is_binary(value) and byte_size(value) == length do
    with true <- value == String.downcase(value),
         {id, ""} when id > 0 <- Integer.parse(value, 16) do
      id
    else
      _other -> nil
    end
  end

  defp hex_id(_value, _length), do: nil

  @otlp_kinds %{
    1 => :internal,
    2 => :server,
    3 => :client,
    4 => :producer,
    5 => :consumer,
    "SPAN_KIND_INTERNAL" => :internal,
    "SPAN_KIND_SERVER" => :server,
    "SPAN_KIND_CLIENT" => :client,
    "SPAN_KIND_PRODUCER" => :producer,
    "SPAN_KIND_CONSUMER" => :consumer
  }

  defp otlp_kind(kind), do: Map.get(@otlp_kinds, kind, :internal)

  defp otlp_status_code(%{"code" => code}) when code in [1, "STATUS_CODE_OK"], do: :ok
  defp otlp_status_code(%{"code" => code}) when code in [2, "STATUS_CODE_ERROR"], do: :error
  defp otlp_status_code(_status), do: :unset

  defp otlp_status_message(%{"message" => message}) when is_binary(message), do: message
  defp otlp_status_message(_status), do: nil

  # OTLP carries Unix nanoseconds as a string; the SDK's spans carry native
  # monotonic time. Converting keeps a browser span sorted among its server spans.
  defp native_time(nanos) when is_binary(nanos) do
    case Integer.parse(nanos) do
      {value, ""} -> native_time(value)
      _other -> nil
    end
  end

  defp native_time(nanos) when is_integer(nanos) do
    System.convert_time_unit(nanos, :nanosecond, :native) - System.time_offset(:native)
  end

  defp native_time(_nanos), do: nil

  defp otlp_attributes(attributes) when is_list(attributes) do
    for %{"key" => key, "value" => value} <- attributes,
        is_binary(key),
        decoded = otlp_value(value),
        not is_nil(decoded),
        into: %{} do
      {key, decoded}
    end
  end

  defp otlp_attributes(_attributes), do: %{}

  defp otlp_value(%{"stringValue" => value}) when is_binary(value), do: value
  defp otlp_value(%{"boolValue" => value}) when is_boolean(value), do: value
  defp otlp_value(%{"doubleValue" => value}) when is_number(value), do: value

  defp otlp_value(%{"intValue" => value}) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _other -> nil
    end
  end

  defp otlp_value(%{"intValue" => value}) when is_integer(value), do: value

  defp otlp_value(%{"arrayValue" => %{"values" => values}}) when is_list(values) do
    Enum.map(values, &otlp_value/1)
  end

  defp otlp_value(_value), do: nil

  defp otlp_event(event) do
    %{name: name(event["name"] || ""), attributes: otlp_attributes(event["attributes"])}
  end

  defp otlp_link(link) do
    with trace_id when is_integer(trace_id) <- hex_id(link["traceId"], 32),
         span_id when is_integer(span_id) <- hex_id(link["spanId"], 16) do
      [%{trace_id: trace_id, span_id: span_id, attributes: otlp_attributes(link["attributes"])}]
    else
      _malformed -> []
    end
  end
end
