defmodule AshEnterprise.Telemetry.AshTracerTest do
  use ExUnit.Case, async: true

  alias AshEnterprise.Telemetry.AshTracer

  import AshEnterprise.Telemetry.TraceHelpers

  defp with_ash_span(fun) do
    key = test_key!()
    :ok = AshTracer.start_span(:action, "ash.action.test")
    fun.()
    :ok = AshTracer.stop_span()
    span_named(key, "ash.action.test")
  end

  test "an invalid input is not a span error" do
    span =
      with_ash_span(fn ->
        AshTracer.set_handled_error(Ash.Error.Invalid.exception(errors: []), [])
      end)

    assert span.status_code == :unset
    assert attr(span, "ash.error.class") == "invalid"
    assert span.events == []
  end

  test "a forbidden action is not a span error" do
    span =
      with_ash_span(fn ->
        AshTracer.set_handled_error(Ash.Error.Forbidden.exception(errors: []), [])
      end)

    assert span.status_code == :unset
    assert attr(span, "ash.error.class") == "forbidden"
  end

  test "a framework fault sets the error status and records an exception event" do
    error = Ash.Error.Unknown.exception(errors: [])
    span = with_ash_span(fn -> AshTracer.set_handled_error(error, stacktrace: []) end)

    assert span.status_code == :error
    assert attr(span, "ash.error.class") == nil
    assert [%{name: "exception", attributes: attributes}] = span.events
    assert attributes[:"exception.type"] =~ "Ash.Error.Unknown"
  end

  test "a raised fault records the same event, with no options given" do
    span = with_ash_span(fn -> AshTracer.set_error(RuntimeError.exception("db down")) end)

    assert span.status_code == :error
    assert [%{name: "exception", attributes: attributes}] = span.events
    assert attributes[:"exception.message"] == "db down"
  end

  test "a non-exception error does not raise" do
    span = with_ash_span(fn -> assert AshTracer.set_error(:not_an_exception) == :ok end)
    assert span.events == []
  end

  test "outside a span it is a no-op" do
    assert AshTracer.set_handled_error(RuntimeError.exception("x"), []) == :ok
  end
end
