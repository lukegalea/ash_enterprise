defmodule AshEnterprise.Mdm.BatchWorker do
  @moduledoc """
  The Oban worker driving one import batch's pipeline.

  Everything inside runs under the batch's correlation id
  (`Platform.Correlation.with_correlation/2`) and is bracketed by
  `Lineage.ingestion_event/4` start/complete(/fail) — the run id IS the
  batch's correlation id, so the OpenLineage graph and the audit
  `metadata["correlation_id"]` agree by construction (ADR 0054 §11).

  Idempotent by construction: re-running a batch re-lands nothing (bizev's
  temporal landing is a no-op on identical content) and re-stages nothing
  (StagedRecord's `one_per_source_record` identity). A crash re-raises for
  Oban's retry machinery, and the retry carries on where the failed execution
  stopped: the batch keeps its status and its landing cursor. Only the last
  attempt's crash ends the batch: it is marked :failed, the lineage :fail
  event is emitted, and the stored upload is removed, since nothing will read
  it again. A snooze is not an attempt (Oban gives it back), so the slices of
  a long import do not use up the retries.

  A bulk upload (`AshEnterprise.Mdm.BulkImport`) arrives as an `"upload_id"`
  argument: the worker lands the file first, a chunk at a time, in slices of
  about a minute. After a slice that did not reach the end of the file the
  job snoozes and the next execution carries on from the cursor the batch
  records, so no execution runs long enough for Oban's Lifeline (5 minutes)
  to rescue it as an orphan and run a second copy beside it. Once every row
  is done the worker stages as of the instant landing finished, so every row
  it landed is seen, and removes the stored file. Without an upload the rows
  were landed before the batch opened, and staging reads as of the batch's
  open instant.
  """

  use Oban.Worker,
    queue: :mdm,
    max_attempts: 3,
    unique: [period: 300, states: [:available, :scheduled, :executing, :retryable]]

  require Ash.Query

  @impl true
  def perform(%Oban.Job{args: %{"batch_id" => batch_id, "tenant" => tenant} = args} = job) do
    batch = AshEnterprise.Mdm.ImportBatch.by_id!(batch_id, tenant: tenant, authorize?: false)
    upload_id = args["upload_id"]
    deadline = System.monotonic_time(:millisecond) + AshEnterprise.Mdm.BulkImport.slice_ms()

    try do
      AshEnterprise.Platform.Correlation.with_correlation(batch.correlation_id, fn ->
        # Once per run, on its first execution, not once per slice.
        if batch.status == :open do
          AshEnterprise.Lineage.ingestion_event(:start, "mdm", "batch:#{batch.id}",
            run_id: batch.correlation_id,
            inputs: ["bizev:#{batch.source_slug}"],
            outputs: ["mdm_staged_records"]
          )
        end

        case land_upload(batch, upload_id) do
          :more ->
            {:snooze, 1}

          landing ->
            case stage_batch(batch, landing, deadline) do
              {:more, _staged} ->
                {:snooze, 1}

              {:ok, staged_count} ->
                AshEnterprise.Lineage.ingestion_event(:complete, "mdm", "batch:#{batch.id}",
                  run_id: batch.correlation_id,
                  inputs: ["bizev:#{batch.source_slug}"],
                  outputs: ["mdm_staged_records"]
                )

                AshEnterprise.Mdm.BulkImport.discard(upload_id)
                {:ok, %{staged: staged_count}}
            end
        end
      end)
    rescue
      reason ->
        if last_attempt?(job), do: fail!(batch, upload_id, reason)
        reraise reason, __STACKTRACE__
    end
  end

  defp last_attempt?(%Oban.Job{attempt: attempt, max_attempts: max}), do: attempt >= max

  # No retry follows: the batch ends as :failed, the lineage run fails, and the
  # stored file goes, since nothing will land from it again.
  defp fail!(batch, upload_id, reason) do
    AshEnterprise.Lineage.ingestion_event(:fail, "mdm", "batch:#{batch.id}",
      run_id: batch.correlation_id,
      inputs: ["bizev:#{batch.source_slug}"]
    )

    # The batch as it now stands: staging may already have written it, and
    # `version_number` is an optimistic lock (ADR 0059).
    batch.id
    |> AshEnterprise.Mdm.ImportBatch.by_id!(tenant: batch.organization_id, authorize?: false)
    |> Ash.Changeset.for_update(:fail, %{failure_reason: inspect(reason)},
      tenant: batch.organization_id,
      authorize?: false
    )
    |> Ash.update!(tenant: batch.organization_id, authorize?: false)

    AshEnterprise.Mdm.BulkImport.discard(upload_id)
  end

  # No upload: the rows landed before the batch opened.
  defp land_upload(_batch, nil), do: nil

  # A slice of the upload; `BulkImport.land/3` keeps the cursor on the batch.
  defp land_upload(batch, upload_id) do
    case AshEnterprise.Mdm.BulkImport.land(batch, upload_id) do
      {:ok, totals} ->
        totals

      {:more, _totals} ->
        :more

      {:error, reason} ->
        raise AshEnterprise.Mdm.MatchError,
          message: "the upload for batch #{batch.id} could not be landed: #{inspect(reason)}"
    end
  end

  # Staging and matching share the execution's deadline with landing. Both
  # carry on where an earlier execution stopped: a row already staged is not
  # staged again, and a matched row has left `:staged`. Past the deadline the
  # step returns `{:more, n}` and the job snoozes, so no execution outlives
  # Oban's Lifeline.
  defp stage_batch(batch, landing, deadline) do
    tenant = batch.organization_id

    # Landing wrote its counters onto the batch since it was read.
    batch =
      if landing,
        do: AshEnterprise.Mdm.ImportBatch.by_id!(batch.id, tenant: tenant, authorize?: false),
        else: batch

    batch =
      batch
      |> Ash.Changeset.for_update(:begin_staging, %{}, tenant: tenant, authorize?: false)
      |> Ash.update!(tenant: tenant, authorize?: false)

    rules = mapping_rules!(batch, tenant)

    {state, staged} =
      batch
      |> unstaged_source_records(tenant, landing)
      |> Enum.reduce_while({:done, 0}, fn record, {_state, staged} ->
        staged = if stage_one(batch, tenant, rules, record), do: staged + 1, else: staged
        if past?(deadline), do: {:halt, {:more, staged}}, else: {:cont, {:done, staged}}
      end)

    transition = if state == :more, do: :begin_staging, else: :begin_matching
    record_staged!(batch, tenant, staged, transition)

    cond do
      state == :more -> {:more, staged}
      run_match(batch, tenant, deadline) == :more -> {:more, staged}
      true -> {:ok, staged}
    end
  end

  defp mapping_rules!(batch, tenant) do
    AshEnterprise.Mdm.Mapping
    |> Ash.Query.filter(id == ^batch.mapping_id)
    |> Ash.read_one!(tenant: tenant, authorize?: false)
    |> case do
      %{field_rules: rules} -> rules
      nil -> raise AshEnterprise.Mdm.MappingMissing, batch_id: batch.id
    end
  end

  defp unstaged_source_records(batch, tenant, landing) do
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
    AshEnterprise.Mdm.SourceRecord
    |> Ash.Query.filter(
      source == :manual_csv and stream == :upload and
        source_metadata["tenant"] == ^tenant and source_metadata["slug"] == ^batch.source_slug
    )
    # As-of the batch's open instant: a changed re-land produces multiple
    # periods for one identity, and staging must see exactly ONE of them
    # — the version that was current when the batch pinned its mapping.
    |> Ash.Query.as_of(staging_instant(batch, landing))
    |> Ash.read!(authorize?: false)
    |> Enum.reject(&MapSet.member?(already_staged, &1.id))
  end

  # Adds this execution's staged rows to the batch's counter, and moves the
  # batch on (`:begin_matching`) or keeps it staging (`:begin_staging`).
  defp record_staged!(batch, tenant, staged, transition) do
    prior = (batch.counts || %{})["staged"] || 0
    counts = Map.put(batch.counts || %{}, "staged", prior + staged)

    AshEnterprise.Mdm.ImportBatch
    |> Ash.Query.filter(id == ^batch.id)
    |> Ash.read_one!(tenant: tenant, authorize?: false)
    |> Ash.Changeset.for_update(transition, %{}, tenant: tenant, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:counts, counts)
    |> Ash.update!(tenant: tenant, authorize?: false)
  end

  defp past?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  # An upload landed inside this run, after the batch opened: stage as of the
  # instant it finished. Otherwise the version current when the batch opened.
  defp staging_instant(_batch, %{as_of: as_of}), do: as_of
  defp staging_instant(batch, nil), do: batch.inserted_at

  # MDM-3: blocking + scoring. Candidate generation is SYSTEM work
  # (ADR 0017's first sharp edge): it must see across the actors' grant
  # boundaries, and the review surface — not this step — is what is
  # filtered per viewer.
  defp run_match(batch, tenant, deadline) do
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

    case rule_set do
      %AshEnterprise.Mdm.MatchRuleSet{} ->
        match_until(staged_records, batch, rule_set, tenant, deadline)

      _skipped ->
        :done
    end
  end

  defp match_until(staged_records, batch, rule_set, tenant, deadline) do
    Enum.reduce_while(staged_records, :done, fn staged, :done ->
      match_staged(staged, batch, rule_set, tenant)
      if past?(deadline), do: {:halt, :more}, else: {:cont, :done}
    end)
  end

  defp match_staged(staged, batch, rule_set, tenant) do
    candidates = block(staged, tenant)
    score_candidates(staged, candidates, rule_set, tenant)

    # The bands that decided spent the staged row (:merged/:created) or
    # moved it to the steward (:review). Only an undecided row — no band
    # table, or bands that route nothing — stays staged-work-in-progress.
    unless band_candidates(batch, staged, tenant) do
      staged
      |> Ash.Changeset.for_update(:update, %{status: :matched},
        tenant: tenant,
        authorize?: false
      )
      |> Ash.update!(tenant: tenant, authorize?: false)
    end
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
        |> Ash.Query.filter(email_bidx == ^AshEnterprise.Erasure.BlindIndex.of(tenant, email))
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
  # Band routing (MDM-4/5): the DMN band table — `admit | review | omit` —
  # never a literal. The band lands on the candidate, then routes:
  #
  #   * `:admit`  → the top-scoring admit-banded candidate auto-merges
  #     (`AutoMerge.admit!/4`): nobody decided anything, the published band
  #     table did, and its certification is the provenance.
  #   * `:review` → the candidate becomes stewardship work (queue + the
  #     `mdm.steward_review` process instance when a baseline is published).
  #   * `:omit`   → no golden fits; the staged row becomes its own golden
  #     (`AutoMerge.new_golden!/5`), owned by whoever opened the import.
  #
  # Returns true when a band ROUTED the row somewhere (the caller then does
  # not mark it :matched); false when the row stays undecided.
  defp band_candidates(batch, staged, tenant) do
    candidates =
      AshEnterprise.Mdm.MatchCandidate
      |> Ash.Query.filter(staged_record_id == ^staged.id and status == :pending and is_nil(band))
      # "The" admit (or review, or omit) candidate is the top-scoring one, not
      # whichever row the database returned first: highest score first, ties
      # broken by id so the pick is deterministic.
      |> Ash.Query.sort(score: :desc, id: :asc)
      |> Ash.read!(tenant: tenant, authorize?: false)

    banded = Enum.map(candidates, &{&1, band_of(&1, tenant)})

    admit = Enum.find(banded, fn {_c, band} -> band == :admit end)
    review = Enum.find(banded, fn {_c, band} -> band == :review end)
    omit = Enum.find(banded, fn {_c, band} -> band == :omit end)

    cond do
      admit -> route_admit(admit, banded, staged, tenant)
      review -> route_review(review, banded, batch, staged, tenant)
      # Nothing in the golden store fit — the same verdict as :omit: the
      # row becomes its own golden. An email collision with an existing
      # person is NOT a merge: the row goes back to stewardship.
      candidates == [] -> safe_new_golden(staged, batch, tenant) == :ok
      omit -> route_omit(omit, staged, batch, tenant)
      # Unbanded (no published band table): the row stays undecided —
      # staging worked, routing has not happened yet.
      true -> false
    end
  end

  defp band_of(candidate, tenant) do
    case AshEnterprise.Mdm.Banding.band(candidate.score, tenant, banding_id: candidate.id) do
      {:ok, band} ->
        band

      # No published band table in this tenant's resolver chain: the
      # candidates stay PENDING and un-banded — a staging-only import,
      # not a failure. Bands tighten via calibration; publishing is the
      # operator's act.
      {:error, {:no_published_baseline, _, _}} ->
        nil

      {:error, :no_platform_organization} ->
        nil

      {:error, reason} ->
        raise AshEnterprise.Mdm.MatchError,
          message: "banding failed for candidate #{candidate.id}: #{inspect(reason)}"
    end
  end

  defp route_admit({candidate, _band}, banded, staged, tenant) do
    system = AshEnterprise.Platform.SystemActor.system()
    supersede_others!(banded, candidate, tenant, system)
    # The banded row, not the one read before banding: the merge writes the
    # candidate again, and `version_number` is an optimistic lock (ADR 0059).
    candidate = set_band!(candidate, :admit, tenant, system)

    AshEnterprise.Mdm.AutoMerge.admit!(
      candidate,
      staged,
      golden_for!(candidate, tenant),
      tenant
    )

    true
  end

  defp route_review({candidate, _band}, banded, batch, staged, tenant) do
    system = AshEnterprise.Platform.SystemActor.system()
    supersede_others!(banded, candidate, tenant, system)
    candidate = set_band!(candidate, :review, tenant, system)

    start_steward_review!(batch, candidate, tenant)

    # The staged row moves to the steward with its candidate: it is
    # neither merged nor a new golden yet.
    staged
    |> Ash.Changeset.for_update(:update, %{status: :review},
      tenant: tenant,
      authorize?: false
    )
    |> Ash.update!(tenant: tenant, authorize?: false)

    true
  end

  defp route_omit({candidate, _band}, staged, batch, tenant) do
    candidate =
      set_band!(candidate, :omit, tenant, AshEnterprise.Platform.SystemActor.system())

    case safe_new_golden(staged, batch, tenant, candidate) do
      :ok ->
        true

      {:collision, existing} ->
        route_collision_to_stewardship!(staged, existing, tenant)
        true
    end
  end

  defp set_band!(candidate, band, tenant, system) do
    candidate
    |> Ash.Changeset.for_update(:update, %{band: band},
      tenant: tenant,
      actor: system,
      authorize?: true
    )
    |> Ash.update!(tenant: tenant, actor: system, authorize?: true)
  end

  # Candidates that proposed pairings the routing did not take are spent:
  # they would otherwise sit pending forever against a decided row.
  defp supersede_others!(banded, winner, tenant, system) do
    for {other, _band} <- banded, other.id != winner.id do
      other
      |> Ash.Changeset.for_update(:update, %{status: :superseded},
        tenant: tenant,
        actor: system,
        authorize?: true
      )
      |> Ash.update!(tenant: tenant, actor: system, authorize?: true)
    end

    :ok
  end

  # An email collision on the new-golden path is a steward question, not a
  # merge: leave the row undecided (:matched) and let the matcher pair it
  # against the existing person on the next pass.
  defp safe_new_golden(staged, batch, tenant, candidate \\ nil) do
    # Pre-check, not rescue: this runs inside the batch transaction, and a
    # unique_email violation would abort it wholesale. The staged row goes
    # back to undecided for a steward pass instead.
    mapped = staged.mapped || %{}
    email = mapped["email"]

    existing =
      email &&
        AshEnterprise.Canonical.Person
        |> Ash.Query.filter(email_bidx == ^AshEnterprise.Erasure.BlindIndex.of(tenant, email))
        |> Ash.read_one!(tenant: tenant, authorize?: false)

    if existing do
      {:collision, existing}
    else
      AshEnterprise.Mdm.AutoMerge.new_golden!(candidate, staged, uploader!(batch, tenant), tenant)
      :ok
    end
  end

  # An email collision on the new-golden path means the existing person IS
  # probably the match the rules could not see: stage the row for a
  # steward (status :review) and open a review candidate on the existing
  # person, so a human decides instead of the database erroring.
  defp route_collision_to_stewardship!(staged, existing, tenant) do
    system = AshEnterprise.Platform.SystemActor.system()

    staged
    |> Ash.Changeset.for_update(:update, %{status: :review}, tenant: tenant, authorize?: false)
    |> Ash.update!(tenant: tenant, authorize?: false)

    # The scorer may already have paired the row with this person (blocking
    # reads exact email): the review is the outcome either way, so a second
    # pairing is not written.
    paired? =
      AshEnterprise.Mdm.MatchCandidate
      |> Ash.Query.filter(
        staged_record_id == ^staged.id and golden_id == ^existing.id and
          golden_resource == "AshEnterprise.Canonical.Person"
      )
      |> Ash.exists?(tenant: tenant, authorize?: false)

    unless paired? do
      AshEnterprise.Mdm.MatchCandidate
      |> Ash.Changeset.for_create(:create, %{
        staged_record_id: staged.id,
        golden_resource: "AshEnterprise.Canonical.Person",
        golden_id: existing.id,
        score: Decimal.new("1.0"),
        explanation: %{"rules" => [%{"rule" => "email_collision", "score" => "1.0"}]}
      })
      |> Ash.create!(tenant: tenant, authorize?: false)
      |> then(fn candidate ->
        candidate
        |> Ash.Changeset.for_update(:update, %{band: :review}, tenant: tenant, actor: system)
        |> Ash.update!(tenant: tenant, actor: system)
      end)
    end

    :ok
  end

  defp golden_for!(candidate, tenant) do
    Ash.get!(AshEnterprise.Canonical.Person, candidate.golden_id,
      tenant: tenant,
      authorize?: false
    )
  end

  defp uploader!(batch, tenant) do
    Ash.get!(AshEnterprise.Accounts.User, batch.created_by_id, tenant: tenant, authorize?: false)
  end

  defp start_steward_review!(batch, candidate, tenant) do
    # The process instance is the work item's ledger side — the queue reads
    # the candidate, TaskList reads the task, and the steward's decision
    # (wherever made) completes the task. The definition resolves through
    # the host Resolver (binding → platform baseline), not the engine's
    # in-tenant fallback, because baselines live in the platform
    # organization.
    case AshEnterprise.Process.Resolver.resolve(:process, "mdm.steward_review", tenant) do
      {:ok, definition} ->
        # The struct, not the id: the engine's own lookup reads the
        # definition in the instance's tenant, and the baseline lives in the
        # platform organization. Passing the pinned definition is the
        # package's documented answer.
        # The correlation id joins the stewardship task to the import that
        # caused it — the lineage thread end to end.
        AshBpmn.start_instance!(AshEnterprise.Bpmn,
          definition: definition,
          subject: candidate,
          actor: AshEnterprise.Platform.SystemActor.system(),
          tenant: tenant,
          correlation_id: batch.correlation_id
        )

      # No steward-review baseline: the queue still works, there is just no
      # process instance. Publishing is the operator's act.
      {:error, _reason} ->
        :ok
    end
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
