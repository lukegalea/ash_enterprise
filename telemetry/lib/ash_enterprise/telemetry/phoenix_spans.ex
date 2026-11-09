defmodule AshEnterprise.Telemetry.PhoenixSpans do
  @moduledoc false

  # Replaces OpentelemetryPhoenix's LiveView handler with one that:
  #
  #   * cannot be detached by a failure. The library interpolates the event into the
  #     span name, so a client pushing an event whose name is a map raised, and
  #     `:telemetry` detached the handler for all twelve events on the node;
  #   * caps the event name, which the client chose;
  #   * records a failure without its arguments or the values its message prints.

  alias AshEnterprise.Telemetry.Sanitize

  @library_handler {OpentelemetryPhoenix, :live_view}
  @max_event_bytes 128
  @invalid_event "[invalid]"

  @events for prefix <- [
                [:phoenix, :live_view, :mount],
                [:phoenix, :live_view, :handle_params],
                [:phoenix, :live_view, :handle_event],
                [:phoenix, :live_component, :handle_event]
              ],
              suffix <- [:start, :stop, :exception],
              do: prefix ++ [suffix]

  @doc "Swaps the handler. Must run straight after `OpentelemetryPhoenix.setup/1`."
  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    :ok = :telemetry.detach(@library_handler)

    :telemetry.attach_many({__MODULE__, :span}, @events, &__MODULE__.handle_span/4, %{})
  end

  @doc false
  def handle_span(event, measurements, meta, config) do
    meta = meta |> safe_event_name() |> safe_failure(List.last(event))
    OpentelemetryPhoenix.handle_liveview_event(event, measurements, meta, config)
    :ok
  catch
    _kind, _reason -> :ok
  end

  defp safe_event_name(%{event: name} = meta) when is_binary(name),
    do: %{meta | event: Sanitize.truncate(name, @max_event_bytes)}

  defp safe_event_name(%{event: _not_a_name} = meta), do: %{meta | event: @invalid_event}
  defp safe_event_name(meta), do: meta

  defp safe_failure(%{kind: kind, reason: reason, stacktrace: stacktrace} = meta, :exception) do
    %{
      meta
      | reason: safe_reason(kind, reason, stacktrace),
        stacktrace: Sanitize.stacktrace(stacktrace)
    }
  end

  defp safe_failure(meta, _suffix), do: meta

  # Normalized here, against the original frames: Erlang's `{:badmatch, value}` only
  # becomes a MatchError holding that value once it is normalized.
  defp safe_reason(:error, reason, stacktrace) do
    :error |> Exception.normalize(reason, stacktrace) |> Sanitize.exception()
  end

  defp safe_reason(_kind, reason, _stacktrace), do: reason
end
