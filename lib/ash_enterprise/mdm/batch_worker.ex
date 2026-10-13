defmodule AshEnterprise.Mdm.MappingMissing do
  @moduledoc "The batch's pinned mapping row vanished after :open — data integrity, not a bug."
  use Splode.Error, fields: [:batch_id], class: :invalid

  def message(%{batch_id: id}),
    do:
      "the mapping #{id} pinned by batch at open no longer exists — the batch is failed, not retried"
end

defmodule AshEnterprise.Mdm.BatchWorker do
  @moduledoc """
  The Oban worker driving one import batch's pipeline.

  Everything inside runs under the batch's correlation id
  (`Platform.Correlation.with_correlation/2`) and is bracketed by
  `Lineage.ingestion_event/4` start/complete(/fail) — the run id IS the
  batch's correlation id, so the OpenLineage graph and the audit
  `metadata["correlation_id"]` agree by construction (ADR 0050 §11).

  Idempotent by construction: re-running a batch re-lands nothing (bizev's
  temporal landing is a no-op on identical content) and re-stages nothing
  (StagedRecord's `one_per_source_record` identity). A crash marks the
  batch :failed, emits the lineage :fail event, and re-raises for Oban's
  retry machinery.
  """

  use Oban.Worker,
    queue: :mdm,
    max_attempts: 3,
    unique: [period: 300, states: [:available, :scheduled, :executing, :retryable]]

  require Ash.Query

  @impl true
  def perform(%Oban.Job{args: %{"batch_id" => batch_id, "tenant" => tenant}}) do
    batch = AshEnterprise.Mdm.ImportBatch.by_id!(batch_id, tenant: tenant, authorize?: false)

    try do
      AshEnterprise.Platform.Correlation.with_correlation(batch.correlation_id, fn ->
        AshEnterprise.Lineage.ingestion_event(:start, "mdm", "batch:#{batch.id}",
          run_id: batch.correlation_id,
          inputs: ["bizev:#{batch.source_slug}"],
          outputs: ["mdm_staged_records"]
        )

        {:ok, staged_count} = stage_batch(batch)

        AshEnterprise.Lineage.ingestion_event(:complete, "mdm", "batch:#{batch.id}",
          run_id: batch.correlation_id,
          inputs: ["bizev:#{batch.source_slug}"],
          outputs: ["mdm_staged_records"]
        )

        {:ok, %{staged: staged_count}}
      end)
    rescue
      reason ->
        AshEnterprise.Lineage.ingestion_event(:fail, "mdm", "batch:#{batch.id}",
          run_id: batch.correlation_id,
          inputs: ["bizev:#{batch.source_slug}"]
        )

        batch
        |> Ash.Changeset.for_update(:fail, %{failure_reason: inspect(reason)},
          tenant: batch.organization_id,
          authorize?: false
        )
        |> Ash.update!(tenant: batch.organization_id, authorize?: false)

        reraise reason, __STACKTRACE__
    end
  end

  defp stage_batch(batch) do
    tenant = batch.organization_id

    batch
    |> Ash.Changeset.for_update(:begin_staging, %{}, tenant: tenant, authorize?: false)
    |> Ash.update!(tenant: tenant, authorize?: false)

    mapping =
      AshEnterprise.Mdm.Mapping
      |> Ash.Query.filter(id == ^batch.mapping_id)
      |> Ash.read_one!(tenant: tenant, authorize?: false)

    rules =
      case mapping do
        %{field_rules: rules} -> rules
        nil -> raise AshEnterprise.Mdm.MappingMissing, batch_id: batch.id
      end

    prefix = "#{tenant}:#{batch.source_slug}:"

    already_staged =
      AshEnterprise.Mdm.StagedRecord
      |> Ash.Query.filter(batch_id == ^batch.id)
      |> Ash.Query.select(:source_record_id)
      |> Ash.read!(tenant: tenant, authorize?: false)
      |> Enum.map(& &1.source_record_id)
      |> MapSet.new()

    # Equality on the payload-carried tenant/slug — NOT a text range over
    # external_id (Postgres collation ignores punctuation like ":" at the
    # first level, so a range could pull in another org's or slug's rows).
    source_records =
      AshEnterprise.Mdm.SourceRecord
      |> Ash.Query.filter(
        source == :manual_csv and stream == :upload and
          source_metadata["tenant"] == ^tenant and source_metadata["slug"] == ^batch.source_slug
      )
      # As-of the batch's open instant: a changed re-land produces multiple
      # periods for one identity, and staging must see exactly ONE of them
      # — the version that was current when the batch pinned its mapping.
      |> Ash.Query.as_of(batch.inserted_at)
      |> Ash.read!(authorize?: false)
      |> Enum.reject(&MapSet.member?(already_staged, &1.id))

    staged =
      Enum.count(source_records, fn record ->
        stage_one(batch, tenant, rules, record)
      end)

    prior = (batch.counts || %{})["staged"] || 0
    counts = Map.put(batch.counts || %{}, "staged", prior + staged)

    AshEnterprise.Mdm.ImportBatch
    |> Ash.Query.filter(id == ^batch.id)
    |> Ash.read_one!(tenant: tenant, authorize?: false)
    |> Ash.Changeset.for_update(:begin_matching, %{}, tenant: tenant, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:counts, counts)
    |> Ash.update!(tenant: tenant, authorize?: false)

    {:ok, staged}
  end

  defp stage_one(batch, tenant, rules, record) do
    case AshMdm.Mapping.Evaluator.run(rules, record.raw_payload) do
      {:ok, mapped} ->
        AshEnterprise.Mdm.StagedRecord
        |> Ash.Changeset.for_create(:stage, %{
          batch_id: batch.id,
          source_record_id: record.id,
          mapped: mapped,
          validation_findings: %{"errors" => [], "warnings" => []},
          status: :staged
        })
        |> Ash.create!(tenant: tenant, authorize?: false)

        true

      {:error, {:rule, rule, reason}} ->
        AshEnterprise.Mdm.StagedRecord
        |> Ash.Changeset.for_create(:stage, %{
          batch_id: batch.id,
          source_record_id: record.id,
          mapped: %{},
          validation_findings: %{
            "errors" => [
              %{"path" => rule["path"], "op" => rule["op"], "reason" => inspect(reason)}
            ]
          },
          status: :omitted
        })
        |> Ash.create!(tenant: tenant, authorize?: false)

        true
    end
  rescue
    # The one_per_source_record identity lost a race (a concurrent worker
    # staged the same row): not an error — idempotency by construction.
    Ash.Error.Invalid -> false
  end
end
