defmodule AshEnterprise.Telemetry.PostgresTest do
  # Toggles a global application-env flag.
  use ExUnit.Case, async: false

  alias AshEnterprise.Telemetry.Postgres
  alias AshEnterprise.Telemetry.TestRepo
  alias OpenTelemetry.Tracer

  require OpenTelemetry.Tracer

  defmodule ExplodingRepo do
    def query(_sql, _params), do: raise("no connection")
  end

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(TestRepo, shared: false)
    Application.put_env(:ash_enterprise_telemetry, :pg_application_name?, true)

    on_exit(fn ->
      Application.delete_env(:ash_enterprise_telemetry, :pg_application_name?)
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    :ok
  end

  defp application_name do
    %{rows: [[name]]} = TestRepo.query!("SELECT current_setting('application_name')")
    name
  end

  test "sets application_name to the traceparent for the transaction" do
    Tracer.with_span "in.transaction" do
      TestRepo.transaction(fn ->
        assert Postgres.tag_transaction(TestRepo) == :ok
        assert application_name() =~ ~r/^00-[0-9a-f]{32}-[0-9a-f]{16}-0[01]$/
      end)
    end
  end

  test "does nothing when disabled" do
    Application.put_env(:ash_enterprise_telemetry, :pg_application_name?, false)
    before = application_name()

    Tracer.with_span "disabled" do
      TestRepo.transaction(fn ->
        Postgres.tag_transaction(TestRepo)
        assert application_name() == before
      end)
    end
  end

  test "does nothing outside a span" do
    TestRepo.transaction(fn ->
      assert Postgres.tag_transaction(TestRepo) == :ok
      refute application_name() =~ ~r/^00-/
    end)
  end

  test "a failing repo does not raise" do
    Tracer.with_span "exploding" do
      assert Postgres.tag_transaction(ExplodingRepo) == :ok
    end
  end
end
