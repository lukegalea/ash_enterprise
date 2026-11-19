defmodule AshEnterprise.Durability.BulkImportTest do
  @moduledoc """
  The bulk import's in half at size (q42): one CSV of 50,000 rows
  (`BULK_IMPORT_ROWS` overrides the count) goes in through the MDM staged
  import (`AshEnterprise.Mdm.BulkImport`). The batch opens as the tenant's
  admin, and the batch worker runs in a real Oban queue: it lands the file a
  chunk at a time, each row committed, then stages every row, in slices of
  about a minute with the job snoozed between them. Before slicing, one
  execution ran past Oban's Lifeline (5 minutes), was started a second time
  beside itself, and the batch failed on a stale write.

  It runs in the durability tier and not the sandbox, because the sandbox
  never commits. Inside one uncommitted transaction, Postgres keeps the plan it
  cached for the identity lookup while the table was empty, and no ANALYZE
  ever replaces it, so every lookup scans the growing table (measured: 45 rows
  a second at 50,000 rows, against about 350 with custom plans). Committed, the
  table is analyzed as it grows.

  The landing time is the sum of `BulkImport`'s telemetry spans, one per
  slice. The job's time
  covers landing, staging and matching. Both are printed for
  docs/runbooks/bulk-import.md and the q42 answer. The numbers are this fixture
  on CI hardware, not a claim about any deployment. SYNTHETIC data only.
  """

  use AshEnterprise.DurabilityCase, async: false

  import AshEnterprise.Mdm.TestSupport

  alias AshEnterprise.Mdm.{BulkImport, ImportBatch, StagedRecord}
  alias AshEnterprise.Platform.Seeder

  require Ash.Query

  @rows "BULK_IMPORT_ROWS" |> System.get_env("50000") |> String.to_integer()

  # Wall-clock ceilings in milliseconds at 50,000 rows: three times the first CI
  # measurement (ubuntu-latest, run 44264838504: 342 s to land over six slices,
  # 616 s until the batch was staged), recorded in the q42 answer.
  @land_ceiling_ms 1_026_000
  @staged_ceiling_ms 1_849_000

  setup do
    n = System.unique_integer([:positive])

    %{organization: organization, user: admin} =
      Seeder.seed_tenant(name: "Bulk import #{n}", unique_name: "bulk-import-#{n}")

    mapping =
      organization.id
      |> draft_host_mapping!([])
      |> activate_host_mapping!(organization.id, admin)

    %{org: organization.id, admin: admin, mapping: mapping}
  end

  @tag timeout: :infinity
  test "lands 50_000 rows and the batch reaches staged", %{
    org: org,
    admin: admin,
    mapping: mapping
  } do
    path = Path.join(System.tmp_dir!(), "bulk-import-#{System.unique_integer([:positive])}.csv")

    File.open!(path, [:write, :utf8], fn file ->
      IO.write(file, "Email,Full Name\n")

      1..@rows
      |> Stream.map(&"person#{&1}@bulk.example,Person #{&1}\n")
      |> Stream.chunk_every(5_000)
      |> Enum.each(&IO.write(file, &1))
    end)

    {:ok, upload_id} = BulkImport.store_upload(path)
    File.rm!(path)
    on_exit(fn -> BulkImport.discard(upload_id) end)

    assert {:ok, %{row_count: @rows}} = BulkImport.inspect_upload(upload_id)

    test_pid = self()
    handler = "bulk-import-durability-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      BulkImport.land_event() ++ [:stop],
      fn _event, %{duration: duration}, metadata, _config ->
        send(
          test_pid,
          {:landed, System.convert_time_unit(duration, :native, :millisecond), metadata}
        )
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    subscribe_jobs()

    started = System.monotonic_time(:millisecond)

    {:ok, batch, job} =
      BulkImport.start(upload_id, %{mapping_id: mapping.id, source_slug: "bulk"},
        actor: admin,
        tenant: org
      )

    await_job(job.id, :success, :timer.minutes(60))

    # The job subscription sees every job on the node, and other tests' jobs fail on
    # purpose; only an attempt of this import's job counts.
    job_id = job.id

    receive do
      {:oban_job, ^job_id, :failure, meta} ->
        flunk("an attempt failed: #{inspect(meta[:error] || meta[:reason], limit: 20)}")
    after
      0 -> :ok
    end

    job_ms = System.monotonic_time(:millisecond) - started

    # One stop event per landing slice; the last says landing is done.
    slices = collect_slices([])
    land_ms = slices |> Enum.map(&elem(&1, 0)) |> Enum.sum()

    assert {_ms, %{batch_id: batch_id, landed: @rows, refused: 0, done?: true}} =
             List.last(slices)

    assert batch_id == batch.id

    batch = ImportBatch.by_id!(batch.id, tenant: org, authorize?: false)

    assert batch.status != :failed, "the batch failed: #{batch.failure_reason}"
    assert batch.counts["landed"] == @rows
    assert batch.counts["refused"] == 0
    assert batch.counts["staged"] == @rows

    staged =
      StagedRecord
      |> Ash.Query.filter(batch_id == ^batch.id)
      |> Ash.count!(tenant: org, authorize?: false)

    assert staged == @rows

    # The stored file is removed once the batch has staged.
    assert {:error, :unknown_upload} = BulkImport.upload_path(upload_id)

    if @rows == 50_000 do
      assert land_ms <= @land_ceiling_ms,
             "landing took #{land_ms}ms; the ceiling is #{@land_ceiling_ms}ms"

      assert job_ms <= @staged_ceiling_ms,
             "the batch was staged after #{job_ms}ms; the ceiling is #{@staged_ceiling_ms}ms"
    end

    IO.puts(
      "[bulk-import] #{@rows} rows landed in #{land_ms}ms over #{length(slices)} slices " <>
        "(#{rate(@rows, land_ms)} rows/s); land + stage + match #{job_ms}ms"
    )
  end

  defp collect_slices(acc) do
    receive do
      {:landed, ms, metadata} -> collect_slices([{ms, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp rate(_rows, 0), do: "n/a"
  defp rate(rows, ms), do: round(rows * 1000 / ms)
end
