defmodule AshEnterprise.Platform.TelemetryCorrelationTest do
  use ExUnit.Case, async: true

  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Platform.TelemetryCorrelation

  test "current never generates an id" do
    assert TelemetryCorrelation.current() == nil
    assert TelemetryCorrelation.current() == nil
  end

  test "start_new keeps an id the process already has, so a LiveView keeps one id" do
    id = Correlation.start_new()

    assert TelemetryCorrelation.start_new() == id
    assert Correlation.id() == id
  end

  test "start_new mints an id when the process has none" do
    id = TelemetryCorrelation.start_new()

    assert is_binary(id)
    assert Correlation.id() == id
  end

  test "put restores an id carried across a process boundary" do
    TelemetryCorrelation.put("carried")

    assert Correlation.id() == "carried"
  end
end
