defmodule AshEnterprise.Telemetry.TaskContextTest do
  use ExUnit.Case, async: true

  alias AshEnterprise.Telemetry.Correlation
  alias AshEnterprise.Telemetry.TaskContext
  alias OpenTelemetry.Tracer

  import AshEnterprise.Telemetry.TraceHelpers

  require OpenTelemetry.Tracer

  test "a task runs under the captured span and correlation" do
    key = test_key!()
    id = Correlation.start_new()

    Tracer.with_span "parent.span" do
      captured = TaskContext.capture()

      task =
        Task.async(fn ->
          TaskContext.run(captured, fn ->
            AshEnterprise.Telemetry.TestKey.put(key)
            Tracer.with_span("child.in.task", do: Correlation.current())
          end)
        end)

      assert Task.await(task) == id
    end

    assert span_named(key, "child.in.task").parent_span_id ==
             span_named(key, "parent.span").span_id
  end

  test "without capture, a task has neither" do
    Correlation.start_new()

    Tracer.with_span "lonely" do
      assert Task.await(Task.async(fn -> {Correlation.current(), Tracer.current_span_ctx()} end)) ==
               {nil, :undefined}
    end
  end

  test "bind captures at call time" do
    id = Correlation.start_new()
    bound = TaskContext.bind(&Correlation.current/0)
    Correlation.put("later")

    assert Task.await(Task.async(bound)) == id
  end

  test "run restores the context afterwards" do
    Correlation.put("outer")

    captured = %TaskContext{ctx: OpenTelemetry.Ctx.new(), correlation: "inner"}

    assert TaskContext.run(captured, &Correlation.current/0) == "inner"
    assert Correlation.current() == "outer"
  end

  test "run restores the context after a raise" do
    Correlation.put("outer")
    captured = %TaskContext{ctx: OpenTelemetry.Ctx.new(), correlation: "inner"}

    assert_raise RuntimeError, fn -> TaskContext.run(captured, fn -> raise "boom" end) end

    assert Correlation.current() == "outer"
  end

  test "a nil correlation leaves the current one in place" do
    Correlation.put("kept")
    captured = %TaskContext{ctx: OpenTelemetry.Ctx.new(), correlation: nil}

    assert TaskContext.run(captured, &Correlation.current/0) == "kept"
  end
end
