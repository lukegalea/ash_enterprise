defmodule AshEnterprise.Telemetry.CorrelationTest do
  use ExUnit.Case, async: true

  alias AshEnterprise.Telemetry.Correlation

  test "current is nil until started, and never generates" do
    assert Correlation.current() == nil
    assert Correlation.current() == nil
  end

  test "start_new mints and stores a fresh id each time" do
    first = Correlation.start_new()
    assert Correlation.current() == first
    assert first != Correlation.start_new()
  end

  test "put sets the current id" do
    Correlation.put("abc")
    assert Correlation.current() == "abc"
  end

  test "with_correlation restores the previous id" do
    Correlation.put("outer")
    assert Correlation.with_correlation("inner", &Correlation.current/0) == "inner"
    assert Correlation.current() == "outer"
  end

  test "with_correlation restores nil and survives a raise" do
    assert_raise RuntimeError, fn ->
      Correlation.with_correlation("inner", fn -> raise "nope" end)
    end

    assert Correlation.current() == nil
  end
end
