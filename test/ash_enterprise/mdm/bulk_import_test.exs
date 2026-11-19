defmodule AshEnterprise.Mdm.BulkImportTest do
  @moduledoc """
  The bulk import's in half (q42): an uploaded file kept on the server, a batch
  opened as the person, and the batch worker landing the file a chunk at a
  time. Refusals first: a person who may not open the batch, a file over the
  cap, a row the landing region does not admit, a forged job naming another
  tenant. Then idempotency, and 5,000 rows across chunk boundaries. The
  50,000-row run is the durability tier's
  (`test/ash_enterprise/durability/bulk_import_test.exs`), where every row
  commits.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Mdm.TestSupport

  alias AshEnterprise.Mdm.{BatchWorker, BulkImport, ImportBatch, ImportRowRefusal, SourceRecord}
  alias AshEnterprise.Mdm.StagedRecord
  alias AshEnterprise.Platform.Seeder
  alias AshEnterprise.Test.DailyFixtures

  require Ash.Query

  setup do
    %{organization: organization, user: admin} = new_tenant()

    mapping =
      activate_host_mapping!(draft_host_mapping!(organization.id, []), organization.id, admin)

    %{org: organization.id, admin: admin, mapping: mapping}
  end

  defp new_tenant do
    n = System.unique_integer([:positive])
    Seeder.seed_tenant(name: "Bulk #{n}", unique_name: "bulk-#{n}")
  end

  defp upload!(csv) do
    path = Path.join(System.tmp_dir!(), "bulk-test-#{System.unique_integer([:positive])}.csv")
    File.write!(path, csv)
    {:ok, upload_id} = BulkImport.store_upload(path)
    File.rm!(path)
    on_exit(fn -> BulkImport.discard(upload_id) end)
    upload_id
  end

  defp people_csv(count) do
    rows = for i <- 1..count, do: "person#{i}@x.io,Person #{i}\n"
    IO.iodata_to_binary(["Email,Full Name\n" | rows])
  end

  defp landed(org, slug) do
    SourceRecord
    |> Ash.Query.filter(
      source == :manual_csv and stream == :upload and source_metadata["tenant"] == ^org and
        source_metadata["slug"] == ^slug
    )
    |> Ash.read!(authorize?: false)
  end

  defp landed_for_slug(slug) do
    SourceRecord
    |> Ash.Query.filter(
      source == :manual_csv and stream == :upload and source_metadata["slug"] == ^slug
    )
    |> Ash.read!(authorize?: false)
  end

  # Snoozed slices are scheduled a second ahead; run them now, and again until
  # the queue is empty.
  defp run_queue,
    do:
      Oban.drain_queue(
        queue: :mdm,
        with_safety: false,
        with_scheduled: true,
        with_recursion: true
      )

  defp rule_set!(org, admin) do
    AshEnterprise.Mdm.MatchRuleSet
    |> Ash.Changeset.for_create(:draft, %{
      golden_resource: "AshEnterprise.Canonical.Person",
      rules: [
        %{"name" => "email_exact", "kind" => "exact", "fields" => ["email"], "weight" => 1.0}
      ]
    })
    |> Ash.create!(tenant: org, authorize?: false)
    |> Ash.Changeset.for_update(:activate, %{}, tenant: org, actor: admin)
    |> Ash.update!(tenant: org, actor: admin)
  end

  defp put_bulk_config(overrides) do
    previous = Application.get_env(:ash_enterprise, BulkImport)
    Application.put_env(:ash_enterprise, BulkImport, Keyword.merge(previous || [], overrides))
    on_exit(fn -> Application.put_env(:ash_enterprise, BulkImport, previous) end)
  end

  defp batch!(org, id), do: ImportBatch.by_id!(id, tenant: org, authorize?: false)

  defp refusals(org, batch_id) do
    ImportRowRefusal
    |> Ash.Query.filter(batch_id == ^batch_id)
    |> Ash.Query.sort(row_number: :asc)
    |> Ash.read!(tenant: org, authorize?: false)
  end

  test "a person who cannot open a batch lands nothing (Forbidden, zero SourceRecords)", %{
    org: org,
    admin: admin,
    mapping: mapping
  } do
    # They may read the mapping and nothing more.
    member =
      DailyFixtures.member!(%{tenant: org, user: admin}, "Mapping reader", [
        {AshEnterprise.Mdm.Mapping, :read, :global}
      ])

    upload_id = upload!(people_csv(3))

    assert {:error, %Ash.Error.Forbidden{}} =
             BulkImport.start(upload_id, %{mapping_id: mapping.id, source_slug: "refused"},
               actor: member.user,
               tenant: org
             )

    run_queue()

    assert landed(org, "refused") == []
    refute ImportBatch |> Ash.exists?(tenant: org, authorize?: false)
  end

  test "rows over the configured cap are refused before any land", %{
    org: org,
    admin: admin,
    mapping: mapping
  } do
    put_bulk_config(max_rows: 3)

    over = upload!(people_csv(4))

    assert {:error, {:over_cap, 3}} = BulkImport.inspect_upload(over)

    assert {:error, {:over_cap, 3}} =
             BulkImport.start(over, %{mapping_id: mapping.id, source_slug: "over-cap"},
               actor: admin,
               tenant: org
             )

    run_queue()

    assert landed(org, "over-cap") == []
    refute ImportBatch |> Ash.exists?(tenant: org, authorize?: false)

    # At the cap, the file is accepted.
    assert {:ok, %{row_count: 3}} = BulkImport.inspect_upload(upload!(people_csv(3)))
  end

  test "an upload id that is not one the store issued is refused", %{
    org: org,
    admin: admin,
    mapping: mapping
  } do
    for forged <- ["../../etc/passwd", Ash.UUID.generate(), nil] do
      assert {:error, :unknown_upload} =
               BulkImport.start(forged, %{mapping_id: mapping.id, source_slug: "forged"},
                 actor: admin,
                 tenant: org
               )
    end

    refute ImportBatch |> Ash.exists?(tenant: org, authorize?: false)
  end

  test "a row with an inadmissible region is reported with its row number and does not land; the rest do",
       %{org: org, admin: admin, mapping: mapping} do
    # Row 2 declares no residency, row 3 one the landing region (:us) does not
    # admit, row 4 the region's own tag in capitals, row 5 is malformed.
    csv = """
    Email,Full Name,Residency
    ann@x.io,Ann,
    eve@x.io,Eve,eu
    sam@x.io,Sam,US
    short@x.io
    """

    upload_id = upload!(csv)

    {:ok, batch, _job} =
      BulkImport.start(upload_id, %{mapping_id: mapping.id, source_slug: "residency"},
        actor: admin,
        tenant: org
      )

    run_queue()

    landed_emails =
      org |> landed("residency") |> Enum.map(& &1.raw_payload["Email"]) |> Enum.sort()

    assert landed_emails == ["ann@x.io", "sam@x.io"]

    assert [
             %{row_number: 3, reason: "inadmissible region: " <> inadmissible},
             %{row_number: 5, reason: "malformed row: 1 fields where the header has 3"}
           ] = refusals(org, batch.id)

    assert inadmissible =~ ~s("eu")
    # The reason names the rule, never the row's values.
    refute inadmissible =~ "eve@x.io"

    batch = batch!(org, batch.id)
    assert batch.counts["landed"] == 2
    assert batch.counts["refused"] == 2
    assert batch.counts["staged"] == 2

    staged =
      StagedRecord
      |> Ash.Query.filter(batch_id == ^batch.id)
      |> Ash.count!(tenant: org, authorize?: false)

    assert staged == 2

    # The stored file is gone once the batch has staged.
    assert {:error, :unknown_upload} = BulkImport.upload_path(upload_id)
  end

  test "refused rows are read through grants, in their own tenant, and no person can write one",
       %{
         org: org,
         admin: admin,
         mapping: mapping
       } do
    {:ok, batch, _job} =
      BulkImport.start(
        upload!("Email,Full Name\nshort@x.io\n"),
        %{mapping_id: mapping.id, source_slug: "report"},
        actor: admin,
        tenant: org
      )

    run_queue()
    assert [%{row_number: 2}] = refusals(org, batch.id)

    # A member with no grant on refusals reads none of them.
    member = DailyFixtures.member!(%{tenant: org, user: admin}, "No refusal grant", [])
    assert ImportRowRefusal |> Ash.read!(tenant: org, actor: member.user) == []

    # Another tenant's administrator, in their own tenant, sees none of them.
    %{organization: other, user: other_admin} = new_tenant()
    assert ImportRowRefusal |> Ash.read!(tenant: other.id, actor: other_admin) == []

    # The batch's own administrator does.
    assert [%{row_number: 2}] = ImportRowRefusal |> Ash.read!(tenant: org, actor: admin)

    # Recording a refusal is the worker's write alone.
    assert {:error, %Ash.Error.Forbidden{}} =
             ImportRowRefusal
             |> Ash.Changeset.for_create(
               :record,
               %{batch_id: batch.id, row_number: 3, reason: "forged"},
               tenant: org,
               actor: admin
             )
             |> Ash.create()

    assert [%{row_number: 2}] = refusals(org, batch.id)
  end

  test "a batch opened in tenant A never lands rows into tenant B", %{
    org: org,
    admin: admin,
    mapping: mapping
  } do
    %{organization: other} = new_tenant()
    upload_id = upload!(people_csv(3))

    {:ok, batch, _job} =
      BulkImport.start(upload_id, %{mapping_id: mapping.id, source_slug: "shared"},
        actor: admin,
        tenant: org
      )

    # A forged job naming the other tenant for this batch finds no batch there
    # and lands nothing.
    assert_raise Ash.Error.Invalid, fn ->
      BatchWorker.perform(%Oban.Job{
        args: %{"batch_id" => batch.id, "tenant" => other.id, "upload_id" => upload_id}
      })
    end

    assert landed_for_slug("shared") == []

    run_queue()

    records = landed_for_slug("shared")
    assert length(records) == 3
    assert Enum.all?(records, &(&1.source_metadata["tenant"] == org))
    assert Enum.all?(records, &String.starts_with?(&1.external_id, org <> ":shared:"))
    assert landed(other.id, "shared") == []
  end

  test "re-running the same upload is idempotent (same row keys, no duplicate source records)", %{
    org: org,
    admin: admin,
    mapping: mapping
  } do
    csv = people_csv(5)
    input = %{mapping_id: mapping.id, source_slug: "again"}

    {:ok, first, _job} = BulkImport.start(upload!(csv), input, actor: admin, tenant: org)
    run_queue()

    before = org |> landed("again") |> Map.new(&{&1.external_id, {&1.id, &1.valid_at}})
    assert map_size(before) == 5
    assert Map.keys(before) |> Enum.sort() == for(i <- 0..4, do: "#{org}:again:upload-#{i}")

    # The same file again, as a second batch over the same dataset.
    {:ok, second, _job} = BulkImport.start(upload!(csv), input, actor: admin, tenant: org)
    run_queue()

    after_rerun = org |> landed("again") |> Map.new(&{&1.external_id, {&1.id, &1.valid_at}})

    # The same identities, and not one new period: identical content lands as
    # a no-op.
    assert after_rerun == before
    assert batch!(org, first.id).counts["landed"] == 5
    assert batch!(org, second.id).counts["landed"] == 5
  end

  # About 70 seconds on a laptop: five chunks landed, then 5,000 rows staged.
  @tag timeout: :timer.minutes(3)
  test "lands 5_000 rows a chunk at a time and the batch reaches staged", %{
    org: org,
    admin: admin,
    mapping: mapping
  } do
    put_bulk_config(chunk_size: 1_000)

    {:ok, batch, _job} =
      BulkImport.start(upload!(people_csv(5_000)), %{mapping_id: mapping.id, source_slug: "five"},
        actor: admin,
        tenant: org
      )

    run_queue()

    batch = batch!(org, batch.id)
    assert batch.counts["landed"] == 5_000
    assert batch.counts["refused"] == 0
    assert batch.counts["staged"] == 5_000
    assert length(landed(org, "five")) == 5_000
  end

  test "the last attempt's crash ends the batch as failed and removes the stored upload", %{
    org: org,
    admin: admin,
    mapping: mapping
  } do
    upload_id = upload!(people_csv(3))

    {:ok, batch, job} =
      BulkImport.start(upload_id, %{mapping_id: mapping.id, source_slug: "last-attempt"},
        actor: admin,
        tenant: org
      )

    # The stored file loses its header: landing cannot start, on any attempt.
    {:ok, path} = BulkImport.upload_path(upload_id)
    File.write!(path, "")

    # Not the last attempt: the batch is left for the retry, and so is the file.
    assert_raise AshEnterprise.Mdm.MatchError, fn ->
      BatchWorker.perform(%{job | attempt: 1, max_attempts: 3})
    end

    refute batch!(org, batch.id).status == :failed
    assert {:ok, ^path} = BulkImport.upload_path(upload_id)

    # The last attempt: nothing retries, so the batch fails and the file goes.
    assert_raise AshEnterprise.Mdm.MatchError, fn ->
      BatchWorker.perform(%{job | attempt: 3, max_attempts: 3})
    end

    failed = batch!(org, batch.id)
    assert failed.status == :failed
    assert failed.failure_reason =~ "could not be landed"
    assert {:error, :unknown_upload} = BulkImport.upload_path(upload_id)
    assert landed(org, "last-attempt") == []
  end

  test "an execution that crashes partway does not end the import: the retry carries on from the cursor to staged",
       %{org: org, admin: admin, mapping: mapping} do
    put_bulk_config(chunk_size: 2, slice_ms: 0)
    upload_id = upload!(people_csv(5))

    {:ok, batch, _job} =
      BulkImport.start(upload_id, %{mapping_id: mapping.id, source_slug: "resume"},
        actor: admin,
        tenant: org
      )

    # One execution lands a chunk, then snoozes.
    assert %{snoozed: 1} = Oban.drain_queue(queue: :mdm, with_scheduled: false)
    assert batch!(org, batch.id).counts["land_cursor"] == 2

    # The next execution crashes: the stored file is gone for a moment.
    {:ok, path} = BulkImport.upload_path(upload_id)
    content = File.read!(path)
    File.rm!(path)

    assert %{failure: 1} =
             Oban.drain_queue(queue: :mdm, with_scheduled: true, with_safety: true)

    crashed = batch!(org, batch.id)
    refute crashed.status == :failed
    assert crashed.counts["land_cursor"] == 2

    # The file is back: the retry carries on from the cursor, lands the rest
    # once, stages every row and removes the file.
    File.write!(path, content)
    assert %{success: 1, failure: 0} = run_queue()

    done = batch!(org, batch.id)
    refute done.status == :failed
    assert %{"land_cursor" => 5, "landed" => 5, "staged" => 5} = done.counts
    assert length(landed(org, "resume")) == 5
    assert {:error, :unknown_upload} = BulkImport.upload_path(upload_id)
  end

  test "the job runs in slices: it snoozes and carries on landing, staging and matching, and a retry lands nothing twice",
       %{org: org, admin: admin, mapping: mapping} do
    # Two rows a chunk, and every execution past its deadline at once: landing
    # takes three slices, then staging and matching go one row an execution.
    put_bulk_config(chunk_size: 2, slice_ms: 0)
    rule_set!(org, admin)
    AshEnterprise.Mdm.Banding.publish_seed_bands!(Seeder.seed_platform_organization().id)

    test_pid = self()
    handler = "bulk-import-slices-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      BulkImport.land_event() ++ [:stop],
      fn _event, _measurements, metadata, _config -> send(test_pid, {:slice, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    upload_id = upload!(people_csv(5))

    {:ok, batch, job} =
      BulkImport.start(upload_id, %{mapping_id: mapping.id, source_slug: "slices"},
        actor: admin,
        tenant: org
      )

    assert %{success: 1, failure: 0, snoozed: snoozed} = run_queue()
    assert snoozed > 3

    assert_received {:slice, %{landed: 2, done?: false}}
    assert_received {:slice, %{landed: 4, done?: false}}
    # A slice cannot tell its last chunk was the file's last, so one more
    # execution finds nothing left and finishes.
    assert_received {:slice, %{landed: 5, done?: false}}
    assert_received {:slice, %{landed: 5, done?: true}}

    batch = batch!(org, batch.id)
    assert %{"land_cursor" => 5, "landed" => 5, "refused" => 0, "staged" => 5} = batch.counts
    assert {:ok, _landed_at, _} = DateTime.from_iso8601(batch.counts["landed_at"])
    assert length(landed(org, "slices")) == 5
    assert {:error, :unknown_upload} = BulkImport.upload_path(upload_id)

    # Every row was staged once and matched: none is left waiting.
    statuses =
      StagedRecord
      |> Ash.Query.filter(batch_id == ^batch.id)
      |> Ash.read!(tenant: org, authorize?: false)
      |> Enum.map(& &1.status)

    assert length(statuses) == 5
    refute :staged in statuses

    # The same job run again (a retry): landing is done, so the file is not
    # needed and nothing lands or stages twice.
    assert {:ok, %{staged: 0}} = BatchWorker.perform(%Oban.Job{args: job.args})
    refute_received {:slice, _}

    batch = batch!(org, batch.id)
    assert batch.counts["landed"] == 5
    assert batch.counts["staged"] == 5
  end
end
