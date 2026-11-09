defmodule AshEnterprise.Telemetry.CrashHandlerTest do
  use ExUnit.Case, async: true

  alias AshEnterprise.Telemetry.CrashHandler
  alias AshEnterprise.Telemetry.FailedSpan
  alias AshEnterprise.Telemetry.TraceSink

  import AshEnterprise.Telemetry.TraceHelpers

  require OpenTelemetry.Tracer

  defp crash_event(meta) do
    %{
      level: :error,
      msg: {:string, "crash"},
      meta: Map.merge(%{gl: self(), pid: self(), time: 0}, meta)
    }
  end

  defp crash_span(key) do
    span_named(key, "process.crash")
  end

  test "a crash becomes a process.crash span with an exception event" do
    key = test_key!()
    reason = %RuntimeError{message: "gen_server died"}

    assert CrashHandler.log(crash_event(%{crash_reason: {reason, []}}), %{config: %{}}) == :ok

    span = crash_span(key)
    assert span.status_code == :error
    assert [%{name: "exception", attributes: attributes}] = span.events
    assert attributes[:"exception.message"] == "gen_server died"
    assert attributes[:"exception.type"] =~ "RuntimeError"
  end

  test "a non-exception exit is still recorded" do
    key = test_key!()
    CrashHandler.log(crash_event(%{crash_reason: {:killed, []}}), %{config: %{}})

    assert [%{attributes: attributes}] = crash_span(key).events
    assert attributes[:"exception.message"] =~ ":killed"
  end

  test "the process's initial call names the crash" do
    key = test_key!()
    Process.put(:"$initial_call", {MyApp.Worker, :init, 1})

    CrashHandler.log(crash_event(%{crash_reason: {:boom, []}}), %{config: %{}})

    assert attr(crash_span(key), :"process.crash.initial_call") == "MyApp.Worker.init/1"
  end

  test "a Bandit crash is skipped, because the request span already has it" do
    key = test_key!()

    CrashHandler.log(crash_event(%{crash_reason: {:boom, []}, domain: [:elixir, :bandit]}), %{
      config: %{}
    })

    refute crash_span(key)
  end

  test "a crash already recorded on a span is skipped" do
    key = test_key!()

    OpenTelemetry.Tracer.with_span "failed.span" do
      FailedSpan.remember()
    end

    CrashHandler.log(crash_event(%{crash_reason: {:boom, []}}), %{config: %{}})

    refute crash_span(key)
  end

  test "a LiveView crash outside an event still records a span" do
    key = test_key!()
    Process.put(:"$initial_call", {Phoenix.LiveView.Channel, :init, 1})

    CrashHandler.log(crash_event(%{crash_reason: {:boom, []}}), %{config: %{}})

    assert crash_span(key)
  end

  test "a configured domain is skipped" do
    key = test_key!()
    event = crash_event(%{crash_reason: {:boom, []}, domain: [:my_lib]})

    CrashHandler.log(event, %{config: %{ignore_domains: [:my_lib]}})

    refute crash_span(key)
  end

  test "an event with no crash reason does nothing" do
    key = test_key!()
    assert CrashHandler.log(crash_event(%{}), %{config: %{}}) == :ok
    refute crash_span(key)
  end

  test "it never raises on malformed input" do
    assert CrashHandler.log(crash_event(%{crash_reason: {:boom, :not_a_list}}), %{config: %{}}) ==
             :ok

    assert CrashHandler.log(:garbage, :garbage) == :ok

    assert CrashHandler.log(%{meta: %{crash_reason: {:boom, []}, domain: :not_a_list}}, %{}) ==
             :ok
  end

  test "a real GenServer crash arrives through the handler" do
    assert :ok = CrashHandler.add()

    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    {:ok, crasher} =
      GenServer.start(AshEnterprise.Telemetry.CrashingServer, self())

    ref = Process.monitor(crasher)
    send(crasher, :crash)
    assert_receive {:DOWN, ^ref, :process, ^crasher, _}, 1_000

    trace =
      eventually(fn ->
        Enum.find(TraceSink.last(200), fn trace ->
          Enum.any?(trace.spans, fn span ->
            span.name == "process.crash" and
              match?([%{attributes: %{"exception.message": "server crashed"}} | _], span.events)
          end)
        end)
      end)

    assert trace
  end
end
