defmodule AshEnterprise.Telemetry.SpanProcessor do
  @moduledoc """
  Stamps every span at start with the correlation id, the acting user and tenant
  (`AshEnterprise.Telemetry.Actor`) and, in tests, the per-test key. List it first in `processors` (`AshEnterprise.Telemetry` shows the config).

  ## Rules

    * **It never generates an id.** It reads what the process already has. A span
      with no correlation in scope has no attribute, which is honest; minting one
      here would give every background sweep a unique id that joins nothing.
    * **A value set by the caller wins.** Code that starts a span for a stored record
      passes that record's correlation id, which is a better answer than the process's.
    * **It never raises.** It runs inside `start_span` and `end_span` on the
      caller's process, so a failure here would take the traced code down.
    * **`on_end` always returns `true`**, on every path. The SDK folds `on_end` as
      `Bool andalso P:on_end(Span, Config) =:= true`, so any other value silently skips
      every processor after this one.

  A span cannot be changed in `on_end`: the SDK takes the span out of storage first
  and hands the record to each processor by value. The error classification that
  needs to change a span's status therefore lives in
  `AshEnterprise.Telemetry.AshTracer`, at the point the error is known.
  """

  @behaviour :otel_span_processor

  alias AshEnterprise.Telemetry.Actor
  alias AshEnterprise.Telemetry.Attributes
  alias AshEnterprise.Telemetry.Settings
  alias AshEnterprise.Telemetry.TestKey

  require Record

  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  Record.defrecordp(
    :span_ctx,
    Record.extract(:span_ctx, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
  )

  @impl :otel_span_processor
  def on_start(ctx, span_record, _config) do
    [
      {Attributes.correlation_id(), correlation()},
      {Attributes.test_key(), TestKey.current()},
      {Attributes.parent_remote(), parent_remote(ctx)}
      | actor()
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.reduce(span_record, fn {key, value}, acc ->
      attributes = span(acc, :attributes)

      if set_by_caller?(attributes, key) do
        acc
      else
        span(acc, attributes: :otel_attributes.set(key, value, attributes))
      end
    end)
  catch
    _kind, _reason -> span_record
  end

  @impl :otel_span_processor
  def on_end(_span_record, _config), do: true

  @impl :otel_span_processor
  def force_flush(_config), do: :ok

  defp actor do
    Enum.map(Actor.current(), fn {key, value} -> {Atom.to_string(key), value} end)
  catch
    _kind, _reason -> []
  end

  defp set_by_caller?(attributes, key) do
    attributes |> :otel_attributes.map() |> Map.keys() |> Enum.any?(&(to_string(&1) == key))
  end

  defp correlation do
    case Settings.correlation().current() do
      id when is_binary(id) -> id
      _other -> nil
    end
  catch
    _kind, _reason -> nil
  end

  # A child copies `is_remote` from its parent's span context, so every descendant of
  # an extracted parent has it set. Only an extracted context is also not recording.
  defp parent_remote(ctx) do
    case OpenTelemetry.Tracer.current_span_ctx(ctx) do
      parent when Record.is_record(parent, :span_ctx) ->
        if span_ctx(parent, :is_remote) and not span_ctx(parent, :is_recording),
          do: true,
          else: nil

      _none ->
        nil
    end
  catch
    _kind, _reason -> nil
  end
end
