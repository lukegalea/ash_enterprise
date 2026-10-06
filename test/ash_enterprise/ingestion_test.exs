defmodule AshEnterprise.IngestionTest do
  @moduledoc """
  Epic E1 acceptance: the tap worker lands Singer output immutably and
  idempotently, and a failing tap fails loudly rather than landing nothing
  silently. The runner is injected, so no external tap is needed to make these
  deterministic.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Ingestion.SourceObject
  alias AshEnterprise.Ingestion.TapWorker

  @opts [authorize?: false]

  # A minimal, well-formed Singer session: two records then a final STATE.
  @singer_output """
  {"type": "SCHEMA", "stream": "users", "schema": {}}
  {"type": "RECORD", "stream": "users", "record": {"id": 1, "email": "a@example.com"}, "time_recorded": "2026-10-06T12:00:00Z"}
  {"type": "RECORD", "stream": "users", "record": {"id": 2, "email": "b@example.com"}}
  {"type": "STATE", "value": {"bookmarks": {"users": {"replication_key_value": 42}}}}
  """

  defmodule StubRunner do
    @behaviour AshEnterprise.Ingestion.TapRunner

    @impl true
    def run(_command) do
      {_, fun} = :persistent_term.get({__MODULE__, :run}, {nil, fn -> {:ok, ""} end})
      fun.()
    end
  end

  setup do
    :persistent_term.put(
      {__MODULE__.StubRunner, :run},
      {nil, fn -> {:ok, @singer_output} end}
    )

    on_exit(fn -> :persistent_term.erase({__MODULE__.StubRunner, :run}) end)
    :ok
  end

  # The app env form cannot hold closures across nodes cleanly in tests; route
  # the worker's runner lookup through what the tests control: the app env
  # points at StubRunner, which reads the canned response from persistent_term.
  setup :configure_runner

  defp configure_runner(_context) do
    original = Application.get_env(:ash_enterprise, AshEnterprise.Ingestion, [])
    env = Keyword.put(original, :tap_runner, __MODULE__.StubRunner)

    Application.put_env(:ash_enterprise, AshEnterprise.Ingestion, env)

    # Restore rather than delete: deleting would also wipe the `pipelines`
    # registration the config files set, failing every test after the first.
    on_exit(fn -> Application.put_env(:ash_enterprise, AshEnterprise.Ingestion, original) end)
    :ok
  end

  describe "TapWorker.perform/1" do
    test "lands each RECORD as an immutable SourceObject with the final STATE as cursor" do
      assert {:ok, %{records: 2, external_system: "postgres"}} =
               TapWorker.perform(%Oban.Job{args: %{"pipeline" => "test_pipeline"}})

      rows = Ash.read!(SourceObject, @opts)
      assert length(rows) == 2

      row = rows |> Enum.find(&(&1.external_id == "1"))
      assert row.raw_payload["email"] == "a@example.com"
      assert row.source_metadata["stream"] == "users"
      assert row.cursor["bookmarks"]["users"]["replication_key_value"] == 42
      assert row.fetched_at == ~U[2026-10-06 12:00:00.000000Z]
    end

    test "re-running the same pass is idempotent -- no duplicate rows" do
      assert {:ok, %{records: 2}} =
               TapWorker.perform(%Oban.Job{args: %{"pipeline" => "test_pipeline"}})

      # A later pass re-emits record 1 with changed payload and a newer cursor.
      updated =
        String.replace(
          @singer_output,
          ~s({"id": 1, "email": "a@example.com"}),
          ~s({"id": 1, "email": "a+changed@example.com"})
        )

      :persistent_term.put({__MODULE__.StubRunner, :run}, {nil, fn -> {:ok, updated} end})

      assert {:ok, %{records: 2}} =
               TapWorker.perform(%Oban.Job{args: %{"pipeline" => "test_pipeline"}})

      rows = Ash.read!(SourceObject, @opts)
      assert length(rows) == 2

      row = rows |> Enum.find(&(&1.external_id == "1"))
      assert row.raw_payload["email"] == "a+changed@example.com"
    end

    test "an unknown pipeline name fails the job" do
      assert {:error, msg} = TapWorker.perform(%Oban.Job{args: %{"pipeline" => "nope"}})
      assert msg =~ "unknown ingestion pipeline"
    end

    test "a missing pipeline argument fails the job" do
      assert {:error, msg} = TapWorker.perform(%Oban.Job{args: %{"tap" => "x"}})
      assert msg =~ "pipeline"
    end

    test "a failing tap propagates the error -- no rows land, no silence" do
      :persistent_term.put(
        {__MODULE__.StubRunner, :run},
        {nil, fn -> {:error, {:exit_status, 1, "boom"}} end}
      )

      assert {:error, {:exit_status, 1, "boom"}} =
               TapWorker.perform(%Oban.Job{args: %{"pipeline" => "test_pipeline"}})

      assert Ash.read!(SourceObject, @opts) == []
    end
  end

  describe "SourceObject" do
    test "reset_cursor drops the stored cursor for a sync-reset" do
      assert {:ok, %{records: 2}} =
               TapWorker.perform(%Oban.Job{args: %{"pipeline" => "test_pipeline"}})

      row = Ash.read!(SourceObject, @opts) |> hd()
      refute is_nil(row.cursor)

      row = SourceObject.reset_cursor!(row, @opts)
      assert is_nil(row.cursor)
    end
  end
end
