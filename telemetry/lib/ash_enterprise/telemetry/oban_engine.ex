defmodule AshEnterprise.Telemetry.ObanEngine do
  @moduledoc """
  A delegating `Oban.Engine` that gives every enqueue a `send <queue>` PRODUCER span
  and stamps the job's meta with the trace context and correlation id.

      config :my_app, Oban, engine: #{inspect(__MODULE__)}

  This one seam covers every insert: `Oban.insert`, `insert_all`, `Ecto.Multi`
  inserts, ash_oban triggers and cron. The stamped span is purpose-built, so a job's
  link points at a named node in the request trace rather than whatever span
  happened to be current.

  ## Behaviour

    * `insert_all` opens **one** span for the batch, with
      `messaging.batch.message_count`. Every job in it shares that span as its link
      target.
    * A job whose meta already has a `traceparent` keeps it (`OpentelemetryOban.insert/2`
      got there first), and any existing `correlation_id` is kept too. Meta the caller
      set is untouched.
    * A job with `unique: [fields: [..., :meta], keys: []]` compares its whole meta, so
      it is left unstamped: a per-enqueue `traceparent` would make every insert unique.
    * Any failure while stamping falls back to the unstamped changeset. Tracing must
      never stop a job being enqueued.

  ## Testing modes

  `testing: :manual` uses this engine. `testing: :inline` does not: Oban swaps in
  `Oban.Engines.Inline` regardless of config, so an inline job has no producer span
  and no stamped meta. It runs in the caller's process, so it is a child of the
  caller's span and keeps its correlation.

  Only the 3-arity inserts are implemented: Oban dispatches the `Ecto.Multi` forms
  through them, and `Oban.Engines.Basic` has no 5-arity inserts to delegate to.
  """

  @behaviour Oban.Engine

  alias Ecto.Changeset
  alias Oban.Engines.Basic

  alias AshEnterprise.Telemetry.Settings

  require OpenTelemetry.Tracer

  @impl Oban.Engine
  def insert_job(conf, changeset, opts) do
    [stamped] = stamp_batch([changeset])
    Basic.insert_job(conf, stamped, opts)
  end

  @impl Oban.Engine
  def insert_all_jobs(conf, changesets, opts) do
    # A caller can pass a stream, and stamping walks the batch more than once.
    Basic.insert_all_jobs(conf, changesets |> Enum.to_list() |> stamp_batch(), opts)
  end

  for {fun, arity} <- Oban.Engine.behaviour_info(:callbacks),
      fun not in [:insert_job, :insert_all_jobs] do
    args = Macro.generate_arguments(arity, __MODULE__)

    @impl Oban.Engine
    def unquote(fun)(unquote_splicing(args)), do: Basic.unquote(fun)(unquote_splicing(args))
  end

  defp stamp_batch(changesets) do
    carrier =
      case Enum.filter(changesets, &traceable?/1) do
        [] -> %{}
        eligible -> producer_carrier(eligible)
      end

    correlation = correlation_entry()
    Enum.map(changesets, &stamp(&1, carrier, correlation))
  catch
    _kind, _reason -> changesets
  end

  defp producer_carrier(eligible) do
    queues = eligible |> Enum.map(&Changeset.get_field(&1, :queue)) |> Enum.uniq()
    name = span_name(queues)

    OpenTelemetry.Tracer.with_span name, %{
      kind: :producer,
      attributes: attributes(eligible, queues)
    } do
      :otel_propagator_text_map.inject([])
      |> Map.new(fn {key, value} -> {to_string(key), to_string(value)} end)
    end
  end

  defp span_name([queue]), do: "send #{queue}"
  defp span_name(_queues), do: "send"

  defp attributes(eligible, queues) do
    base = %{
      "messaging.system": "oban",
      "messaging.operation.name": "send",
      "oban.job.worker": eligible |> hd() |> Changeset.get_field(:worker)
    }

    base =
      if match?([_], queues),
        do: Map.put(base, :"messaging.destination.name", hd(queues)),
        else: base

    case eligible do
      [_one] -> base
      many -> Map.put(base, :"messaging.batch.message_count", length(many))
    end
  end

  defp correlation_entry do
    case Settings.correlation().current() do
      id when is_binary(id) -> %{"correlation_id" => id}
      _none -> %{}
    end
  catch
    _kind, _reason -> %{}
  end

  defp stamp(%Changeset{} = changeset, carrier, correlation) do
    if unique_on_whole_meta?(changeset) do
      changeset
    else
      existing = Changeset.get_field(changeset, :meta) || %{}
      trace = if traceable?(changeset), do: carrier, else: %{}
      correlation = if Map.has_key?(existing, :correlation_id), do: %{}, else: correlation

      # Caller-set keys win: `Map.merge(generated, existing)`.
      Changeset.put_change(
        changeset,
        :meta,
        trace |> Map.merge(correlation) |> Map.merge(existing)
      )
    end
  end

  defp stamp(other, _carrier, _correlation), do: other

  defp traceable?(%Changeset{} = changeset) do
    existing = Changeset.get_field(changeset, :meta) || %{}

    not Map.has_key?(existing, "traceparent") and
      not Map.has_key?(existing, :traceparent) and
      not unique_on_whole_meta?(changeset)
  end

  defp traceable?(_other), do: false

  defp unique_on_whole_meta?(%Changeset{changes: %{unique: %{fields: fields, keys: keys}}}) do
    :meta in fields and keys == []
  end

  defp unique_on_whole_meta?(_changeset), do: false
end
