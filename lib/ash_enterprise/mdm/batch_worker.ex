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

    run_match(batch, tenant)
    {:ok, staged}
  end

  # MDM-3: blocking + scoring. Candidate generation is SYSTEM work
  # (ADR 0017's first sharp edge): it must see across the actors' grant
  # boundaries, and the review surface — not this step — is what is
  # filtered per viewer.
  defp run_match(batch, tenant) do
    rule_set =
      batch.rule_set_id &&
        AshEnterprise.Mdm.MatchRuleSet.by_id(batch.rule_set_id, tenant: tenant, authorize?: false)
        |> elem(1)

    # A batch whose tenant configured no match rule set is a staging-only
    # import — a legitimate flow, not a failure.
    rule_set || {:skipped, :no_rule_set}

    staged_records =
      AshEnterprise.Mdm.StagedRecord
      |> Ash.Query.filter(batch_id == ^batch.id and status == :staged)
      |> Ash.read!(tenant: tenant, authorize?: false)

    with %AshEnterprise.Mdm.MatchRuleSet{} <- rule_set do
      Enum.each(staged_records, fn staged ->
        candidates = block(staged, tenant)
        score_candidates(staged, candidates, rule_set, tenant)
        band_candidates(staged, tenant)

        staged
        |> Ash.Changeset.for_update(:update, %{status: :matched},
          tenant: tenant,
          authorize?: false
        )
        |> Ash.update!(tenant: tenant, authorize?: false)
      end)
    end

    rule_set
  end

  # Blocking (ADR 0017): exact email through Ash + a trigram shortlist on
  # name — `lower(name) % lower($name)` — over the GIN trigram index, so
  # the shortlist is an index read, not an org-wide scan. The reads run as
  # the system actor THROUGH Ash, so the actor lands in the audit trail.
  defp block(staged, tenant) do
    email = staged.mapped["email"]
    name = staged.mapped["name"]
    system = AshEnterprise.Platform.SystemActor.system()

    exact =
      if email do
        AshEnterprise.Canonical.Person
        |> Ash.Query.filter(email == ^email)
        |> Ash.read!(tenant: tenant, actor: system, authorize?: true)
      else
        []
      end

    fuzzy =
      if name && String.trim(name) != "" do
        AshEnterprise.Canonical.Person
        |> Ash.Query.filter(fragment("lower(?) % lower(?)", name, ^String.trim(name)))
        |> Ash.Query.sort(name: :asc)
        |> Ash.Query.limit(50)
        |> Ash.read!(tenant: tenant, actor: system, authorize?: true)
      else
        []
      end

    (exact ++ fuzzy)
    |> Enum.uniq_by(& &1.id)
  end

  defp score_candidates(staged, candidates, rule_set, tenant) do
    rules = rule_set.rules

    Enum.each(candidates, fn person ->
      {score, explanation} =
        AshMdm.Match.score(rules, staged.mapped || %{}, %{
          "email" => person.email && to_string(person.email),
          "name" => person.name
        })

      # The candidate create is audited under the system actor and the
      # batch's correlation id — "who generated this candidate" is the
      # pipeline, not a person.
      # The candidate create is audited under the system actor and the
      # batch's correlation id — "who generated this candidate" is the
      # pipeline, not a person. The actor goes on the CHANGESET: audit
      # metadata is stamped there, not at the final call.
      AshEnterprise.Mdm.MatchCandidate
      |> Ash.Changeset.for_create(
        :create,
        %{
          staged_record_id: staged.id,
          golden_resource: "AshEnterprise.Canonical.Person",
          golden_id: person.id,
          score: score,
          explanation: explanation
        },
        tenant: tenant,
        actor: AshEnterprise.Platform.SystemActor.system(),
        authorize?: true
      )
      |> Ash.create!(
        tenant: tenant,
        actor: AshEnterprise.Platform.SystemActor.system(),
        authorize?: true
      )
    end)
  rescue
    # one_pair identity: a concurrent run scored the same pair. Idempotent.
    Ash.Error.Invalid -> :ok
  end

  # MDM-4: each pending candidate's score goes through the versioned DMN
  # band table — `admit | review | omit` — never a literal. Routing the
  # bands (auto-merge / steward task / new-golden) is MDM-5's slice; here
  # the band lands on the candidate and the batch counts.
  defp band_candidates(staged, tenant) do
    AshEnterprise.Mdm.MatchCandidate
    |> Ash.Query.filter(staged_record_id == ^staged.id and status == :pending and is_nil(band))
    |> Ash.read!(tenant: tenant, authorize?: false)
    |> Enum.each(fn candidate ->
      band_result =
        AshEnterprise.Mdm.Banding.band(candidate.score, tenant, banding_id: candidate.id)

      case band_result do
        {:ok, band} ->
          candidate
          |> Ash.Changeset.for_update(:update, %{band: band},
            tenant: tenant,
            actor: AshEnterprise.Platform.SystemActor.system(),
            authorize?: true
          )
          |> Ash.update!(
            tenant: tenant,
            actor: AshEnterprise.Platform.SystemActor.system(),
            authorize?: true
          )

        # No published band table in this tenant's resolver chain: the
        # candidates stay PENDING and un-banded — a staging-only import,
        # not a failure. Bands tighten via calibration; publishing is the
        # operator's act.
        {:error, {:no_published_baseline, _, _}} ->
          :ok

        {:error, :no_platform_organization} ->
          :ok

        {:error, reason} ->
          raise AshEnterprise.Mdm.MatchError,
            message: "banding failed for candidate #{candidate.id}: #{inspect(reason)}"
      end
    end)
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

defmodule AshEnterprise.Mdm.MatchError do
  @moduledoc "An MDM pipeline step could not proceed (banding failure, missing rule set)."
  use Splode.Error, fields: [:message], class: :invalid

  def message(%{message: m}), do: m
end
