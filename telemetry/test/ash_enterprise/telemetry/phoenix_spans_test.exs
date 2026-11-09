defmodule AshEnterprise.Telemetry.PhoenixSpansTest do
  use ExUnit.Case, async: false

  import AshEnterprise.Telemetry.TraceHelpers

  @handle_event [:phoenix, :live_view, :handle_event]
  @component_event [:phoenix, :live_component, :handle_event]
  @events (for prefix <- [
                 [:phoenix, :live_view, :mount],
                 [:phoenix, :live_view, :handle_params],
                 @handle_event,
                 @component_event
               ],
               suffix <- [:start, :stop, :exception] do
             prefix ++ [suffix]
           end)

  defp meta(event, params \\ %{}) do
    %{
      socket: %{view: __MODULE__, transport_pid: self(), private: %{}},
      event: event,
      params: params
    }
  end

  defp run(prefix \\ @handle_event, meta) do
    :telemetry.span(prefix, meta, fn -> {:ok, meta} end)
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  test "a non-binary event name does not end LiveView spans for the node" do
    key = test_key!()

    assert run(meta(%{"a" => 1})) == :ok
    assert run(@component_event, meta([1, 2])) == :ok

    next = unique("after-bad-event")
    assert run(meta(next)) == :ok

    assert span_named_ending(key, "handle_event##{next}"),
           "the span handler was detached by the bad event"
  end

  test "a non-binary event still gets a span, with a fixed name" do
    key = test_key!()
    run(meta(%{"a" => 1}))

    assert span_named_ending(key, "handle_event#[invalid]")
  end

  test "the handler is attached for all twelve events" do
    for event <- @events do
      ids = event |> :telemetry.list_handlers() |> Enum.map(& &1.id)
      assert {AshEnterprise.Telemetry.PhoenixSpans, :span} in ids
      refute {OpentelemetryPhoenix, :live_view} in ids
    end
  end

  test "a client-chosen event name is capped in the span name" do
    key = test_key!()
    run(meta(String.duplicate("e", 5_000)))

    span = span_named_ending(key, String.duplicate("e", 128))
    assert span
    assert byte_size(span.name) < 300
  end

  test "a failing handler does not crash the traced code" do
    assert run(%{event: "no-socket", params: %{}}) == :ok
  end
end
