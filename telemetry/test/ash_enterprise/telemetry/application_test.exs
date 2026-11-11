defmodule AshEnterprise.Telemetry.ApplicationTest do
  use ExUnit.Case, async: false

  alias AshEnterprise.Telemetry.OtlpIngest

  test "the ingest's owner starts with no browser_ingest config" do
    original = Application.get_env(:ash_enterprise_telemetry, :browser_ingest)
    Application.delete_env(:ash_enterprise_telemetry, :browser_ingest)

    try do
      assert OtlpIngest.Supervisor in AshEnterprise.Telemetry.Application.children()
    after
      Application.put_env(:ash_enterprise_telemetry, :browser_ingest, original)
    end
  end
end
