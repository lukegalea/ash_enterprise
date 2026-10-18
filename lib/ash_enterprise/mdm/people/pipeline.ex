defmodule AshEnterprise.Mdm.People.Pipeline do
  @moduledoc """
  One people sweep for one tenant (PROD-9): land the projected people,
  stage what is new, match, band and route — the CSV batch's pipeline
  (`AshEnterprise.Mdm.BatchWorker`) for a source whose rows are already
  people.

  ## What is different from a CSV row

  A CSV row is a stranger: it either folds into a golden or becomes one. A
  people observation already *is* a person row — the projector made it — so:

    * **Its own person is a candidate.** Blocking finds it by address, the
      rule set scores it like any pair, and the admit band opens the
      observation's source identity there. That is "exact email → admit":
      the Slack and the Calendar sighting of one address are two identities
      of one golden, and no steward sees them.
    * **The other candidates are the same owner's other people**, older than
      this one (so each pair is asked once, and the older row survives),
      not merged, and never asked before (a pending, confirmed, rejected or
      auto-merged pair is the steward's or the band's standing answer — a
      rejected pair is not re-proposed, nor is a pair a steward unmerged).
    * **Admit or confirm merges the person**, not the staged row: the newer
      person folds into the older one (`:mdm_merge_into`), which repoints
      its identities and moves its joins (`AshEnterprise.Mdm.PersonJoins`).
      Review queues the pair; omit leaves the person standing as its own
      golden (staged `:created`).

  Matching, banding and the steward's verdict use the same machinery as the
  import: candidates are generated as the system actor (ADR 0017), bands
  come from the DMN table (`AshEnterprise.Mdm.Banding`), and a review-banded
  pair starts the `mdm.steward_review` process when the tenant has one.

  ## Idempotent (iron law #07)

  Landing an unchanged person is bizev's temporal no-op; staging skips an
  observation whose mapped values a previous sweep already staged; and the
  pair rule above keeps a re-run from asking the same question twice. A
  sweep with nothing new opens no batch at all.

  ## One sweep per tenant at a time

  The cron's job and `mix ash_enterprise.mdm.people` can both start a sweep
  for one tenant, and Oban's uniqueness only covers the job. Two sweeps at
  once would both see the other's rows still `:staged` and stage every
  observation twice. So a sweep holds a per-tenant advisory lock
  (`AshEnterprise.Repo.AdvisoryLock`) and a second one returns `:busy`
  without doing anything; the next tick picks up whatever it would have seen.

  ## Crash-safe

  A sweep killed partway (a closed pipe, a deploy) leaves rows `:staged` and,
  for the row it was routing, candidates nobody routed. The next sweep
  stages those observations again, and supersedes the abandoned rows'
  unrouted candidates first: a pending candidate is a standing answer to the
  pair rule, so left alone it would keep that pair from ever being asked.
  One already banded review stays, since it is in the steward's queue.
  """

  require Ash.Query

  alias AshEnterprise.Canonical.Person
  alias AshEnterprise.Mdm.{ImportBatch, MatchCandidate, People, SourceIdentity, SourceRecord}
  alias AshEnterprise.Mdm.People.Adapter
  alias AshEnterprise.Mdm.StagedRecord
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Repo.AdvisoryLock

  @decided [:pending, :confirmed, :rejected, :auto_merged]
  @lock "mdm.people_sweep"

  @doc """
  Sweeps `tenant`. Returns `{:ok, counts}` (counts only),
  `{:ok, :not_configured}` when the tenant has no active people mapping and
  rule set (`AshEnterprise.Mdm.People.Seed`), or `{:ok, :busy}` when another
  sweep of the tenant is running.
  """
  @spec run(term()) :: {:ok, map() | :not_configured | :busy}
  def run(tenant) do
    mapping = People.mapping(tenant)
    rule_set = People.rule_set(tenant)

    if mapping && rule_set do
      @lock
      |> AdvisoryLock.with_try_lock(to_string(tenant), fn -> sweep(tenant, mapping, rule_set) end)
      |> unlocked()
    else
      {:ok, :not_configured}
    end
  end

  defp unlocked({:ok, result}), do: result
  defp unlocked(:busy), do: {:ok, :busy}

  defp sweep(tenant, mapping, rule_set) do
    {observations, evidence} = Adapter.observe(tenant)
    landed = Adapter.land!(tenant, observations)

    case unstaged(tenant, mapping) do
      [] ->
        {:ok, %{observed: length(observations), landed: landed, staged: 0}}

      pending ->
        batch = open_batch!(tenant, mapping, rule_set)

        counts =
          AshEnterprise.Platform.Correlation.with_correlation(batch.correlation_id, fn ->
            lineage(:start, batch)

            try do
              counts = process!(batch, tenant, mapping, rule_set, evidence, pending)
              lineage(:complete, batch)
              counts
            rescue
              reason ->
                lineage(:fail, batch)
                fail!(batch, reason)
                reraise reason, __STACKTRACE__
            end
          end)

        {:ok, Map.merge(%{observed: length(observations), landed: landed}, counts)}
    end
  end

  # --- staging ---------------------------------------------------------------------

  # Current people landings for the tenant whose mapped values no sweep has
  # staged yet: new people, and people whose name or address changed.
  defp unstaged(tenant, mapping) do
    records =
      SourceRecord
      |> Ash.Query.filter(
        source == ^People.source() and stream == ^People.stream() and
          source_metadata["tenant"] == ^tenant and source_metadata["slug"] == ^People.slug()
      )
      |> Ash.Query.as_of(DateTime.utc_now())
      |> Ash.Query.sort(external_id: :asc)
      |> Ash.read!(authorize?: false)

    staged =
      StagedRecord
      |> Ash.Query.filter(source_record_id in ^Enum.map(records, & &1.id))
      # A row a failed sweep staged but never matched does not count: the
      # next sweep stages it again.
      |> Ash.Query.filter(status != :staged)
      |> Ash.Query.select([:source_record_id, :mapped])
      |> Ash.read!(tenant: tenant, authorize?: false)
      |> MapSet.new(&{&1.source_record_id, &1.mapped})

    for record <- records,
        {:ok, mapped} = AshMdm.Mapping.Evaluator.run(mapping.field_rules, record.raw_payload),
        not MapSet.member?(staged, {record.id, mapped}),
        do: {record, mapped}
  end

  defp open_batch!(tenant, mapping, rule_set) do
    batch =
      ImportBatch
      |> Ash.Changeset.for_create(:open, %{mapping_id: mapping.id, source_slug: People.slug()},
        tenant: tenant,
        actor: SystemActor.system()
      )
      |> Ash.create!(tenant: tenant, actor: SystemActor.system())

    # `:open` pins the active rule set for the mapping's target resource,
    # which is the CSV import's; a people batch is scored by the people rule
    # set, and the batch records which one.
    batch
    |> Ash.Changeset.for_update(:begin_staging, %{}, tenant: tenant, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:rule_set_id, rule_set.id)
    |> Ash.Changeset.force_change_attribute(:rule_set_content_hash, rule_set.content_hash)
    |> Ash.update!(tenant: tenant, authorize?: false)
  end

  defp process!(batch, tenant, mapping, rule_set, evidence, pending) do
    abandon!(Enum.map(pending, fn {record, _mapped} -> record.id end), tenant)

    staged =
      Enum.map(pending, fn {record, mapped} ->
        StagedRecord
        |> Ash.Changeset.for_create(:stage, %{
          batch_id: batch.id,
          source_record_id: record.id,
          mapped: mapped,
          validation_findings: %{"errors" => [], "warnings" => []},
          status: :staged
        })
        |> Ash.create!(tenant: tenant, authorize?: false)
      end)

    batch =
      batch
      |> Ash.Changeset.for_update(:begin_matching, %{}, tenant: tenant, authorize?: false)
      |> Ash.update!(tenant: tenant, authorize?: false)

    context = %{
      batch: batch,
      tenant: tenant,
      mapping: mapping,
      rules: rule_set.rules,
      evidence: evidence
    }

    counts =
      staged
      |> Enum.map(&match!(&1, context))
      |> Enum.frequencies()
      |> Map.put(:staged, length(staged))

    batch
    |> Ash.Changeset.for_update(:begin_matching, %{}, tenant: tenant, authorize?: false)
    |> Ash.Changeset.force_change_attribute(
      :counts,
      Map.new(counts, fn {k, v} -> {Atom.to_string(k), v} end)
    )
    |> Ash.update!(tenant: tenant, authorize?: false)

    counts
  end

  # The rows an interrupted sweep staged for these source records and never
  # finished. Their pending candidates were never routed, and a pending
  # candidate reads as a standing answer (`decided?/4`), so left alone it
  # would keep the restaged row from ever asking its pair. Superseded here,
  # the restaged row asks afresh. A review-banded one stays: it is already
  # in the steward's queue.
  defp abandon!(source_record_ids, tenant) do
    abandoned =
      StagedRecord
      |> Ash.Query.filter(source_record_id in ^source_record_ids and status == :staged)
      |> Ash.Query.select([:id])
      |> Ash.read!(tenant: tenant, authorize?: false)
      |> Enum.map(& &1.id)

    if abandoned != [] do
      MatchCandidate
      |> Ash.Query.filter(
        staged_record_id in ^abandoned and status == :pending and
          (is_nil(band) or band != :review)
      )
      |> Ash.read!(tenant: tenant, authorize?: false)
      |> Enum.each(&set_candidate!(&1, %{status: :superseded}, tenant))
    end

    :ok
  end

  # --- matching --------------------------------------------------------------------

  # Returns the staged row's outcome: :created | :merged | :review | :matched |
  # :omitted.
  defp match!(staged, context) do
    tenant = context.tenant

    case Ash.get(Person, staged.mapped["person_id"],
           tenant: tenant,
           authorize?: false,
           error?: false
         ) do
      {:ok, nil} ->
        set_status!(staged, :omitted, tenant)

      # Already folded into a golden: the observation's identity follows it.
      {:ok, %Person{merged: true, master_id: master_id}} when is_binary(master_id) ->
        ensure_identity!(staged, master_id, :mapping, nil, tenant)
        set_status!(staged, :merged, tenant)

      {:ok, person} ->
        match_person!(staged, person, context)
    end
  end

  defp match_person!(staged, person, context) do
    tenant = context.tenant
    blocked = block(staged.mapped, tenant)
    others = Enum.filter(blocked, &other_candidate?(&1, person, staged, tenant))

    # The row's own person: scored and banded like any pair. When the band
    # does not admit it (a row with nothing comparable), the projection's
    # own assertion still stands — the observation IS that person.
    {own, own_band} = candidate!(staged, person, person, context)

    if own_band == :admit do
      ensure_identity!(staged, person.id, :mapping, own.score, tenant)
      set_candidate!(own, %{band: :admit, status: :auto_merged}, tenant)
    else
      ensure_identity!(staged, person.id, :mapping, nil, tenant)
      set_candidate!(own, %{band: own_band, status: :superseded}, tenant)
    end

    banded =
      others
      |> Enum.map(&candidate!(staged, person, &1, context))
      |> Enum.sort_by(fn {candidate, _band} ->
        {Decimal.to_float(candidate.score) * -1, candidate.golden_id}
      end)

    route!(staged, person, banded, context)
  end

  defp route!(staged, person, banded, context) do
    tenant = context.tenant
    admit = Enum.find(banded, fn {_c, band} -> band == :admit end)
    review = Enum.find(banded, fn {_c, band} -> band == :review end)
    winner = admit || review

    for {candidate, band} <- banded, winner == nil or candidate.id != elem(winner, 0).id do
      status = if band in [:admit, :review, :omit], do: :superseded, else: :pending
      set_candidate!(candidate, %{band: band, status: status}, tenant)
    end

    cond do
      admit ->
        {candidate, _} = admit
        merge!(person, candidate.golden_id, tenant)
        set_candidate!(candidate, %{band: :admit, status: :auto_merged}, tenant)
        set_status!(staged, :merged, tenant)

      review ->
        {candidate, _} = review
        candidate = set_candidate!(candidate, %{band: :review}, tenant)
        start_steward_review!(context.batch, candidate, tenant)
        set_status!(staged, :review, tenant)

      Enum.any?(banded, fn {_c, band} -> is_nil(band) end) ->
        # No published band table: undecided, exactly like an import.
        set_status!(staged, :matched, tenant)

      true ->
        set_status!(staged, :created, tenant)
    end
  end

  # Blocking (ADR 0017), as the system actor through Ash: the address, and
  # the trigram shortlist on name over the GIN index.
  defp block(mapped, tenant) do
    system = SystemActor.system()
    email = mapped["email"]
    name = mapped["name"]

    exact =
      if email do
        Person
        |> Ash.Query.filter(email == ^email)
        |> Ash.read!(tenant: tenant, actor: system, authorize?: true)
      else
        []
      end

    fuzzy =
      if is_binary(name) and String.trim(name) != "" do
        Person
        |> Ash.Query.filter(fragment("lower(?) % lower(?)", name, ^String.trim(name)))
        |> Ash.Query.sort(name: :asc, id: :asc)
        |> Ash.Query.limit(50)
        |> Ash.read!(tenant: tenant, actor: system, authorize?: true)
      else
        []
      end

    Enum.uniq_by(exact ++ fuzzy, & &1.id)
  end

  # Owner-only people pair only with their own owner's people; each pair is
  # asked once, from the newer person towards the older one; and a pair with
  # a standing answer is not asked again.
  defp other_candidate?(golden, person, staged, tenant) do
    golden.id != person.id and not golden.merged and golden.owner_id == person.owner_id and
      older?(golden, person) and not decided?(person.id, golden.id, staged, tenant)
  end

  defp older?(a, b),
    do:
      {DateTime.to_unix(a.inserted_at, :microsecond), a.id} <
        {DateTime.to_unix(b.inserted_at, :microsecond), b.id}

  defp decided?(person_id, golden_id, staged, tenant) do
    staged_ids =
      StagedRecord
      |> Ash.Query.filter(mapped[:person_id] == ^person_id and id != ^staged.id)
      |> Ash.Query.select([:id])
      |> Ash.read!(tenant: tenant, authorize?: false)
      |> Enum.map(& &1.id)

    staged_ids != [] and
      MatchCandidate
      |> Ash.Query.filter(
        golden_id == ^golden_id and staged_record_id in ^staged_ids and status in ^@decided
      )
      |> Ash.exists?(tenant: tenant, authorize?: false)
  end

  # Scores one pair, writes the candidate as the system actor (audited under
  # the batch's correlation id) and bands it. The golden goes through the
  # same mapping as the staged side; the shared-context pair feature is the
  # one thing the matcher adds (see `AshEnterprise.Mdm.People.Seed`).
  defp candidate!(staged, person, golden, context) do
    golden_map =
      golden
      |> Adapter.payload()
      |> map_each(context.mapping.field_rules)
      |> Map.delete("co_occurrence")
      |> then(fn map ->
        if shared_context?(person.id, golden.id, context.evidence),
          do: Map.put(map, "co_occurrence", "shared"),
          else: map
      end)

    {score, explanation} = AshMdm.Match.score(context.rules, staged.mapped || %{}, golden_map)
    system = SystemActor.system()

    candidate =
      MatchCandidate
      |> Ash.Changeset.for_create(
        :create,
        %{
          staged_record_id: staged.id,
          golden_resource: People.golden_resource(),
          golden_id: golden.id,
          score: score,
          explanation: explanation
        },
        tenant: context.tenant,
        actor: system,
        authorize?: true
      )
      |> Ash.create!(tenant: context.tenant, actor: system, authorize?: true)

    {candidate, band_of(candidate, context.tenant)}
  end

  # Each rule on its own, so a golden with no address still yields its
  # name (the evaluator stops at the first failing rule).
  defp map_each(payload, rules) do
    Enum.reduce(rules, %{}, fn rule, acc ->
      case AshMdm.Mapping.Evaluator.run([rule], payload) do
        {:ok, mapped} -> Map.merge(acc, mapped)
        {:error, _} -> acc
      end
    end)
  end

  @doc """
  The shared-context pair feature: the two people are in one event or
  conversation, or share someone they meet or write with. A person shares
  context with themselves.
  """
  def shared_context?(id, id, _evidence), do: true

  def shared_context?(a, b, %{contexts: contexts, members: members}) do
    a_contexts = Map.get(contexts, a, MapSet.new())
    b_contexts = Map.get(contexts, b, MapSet.new())

    not MapSet.disjoint?(a_contexts, b_contexts) or
      not MapSet.disjoint?(
        neighbours(a_contexts, members, [a, b]),
        neighbours(b_contexts, members, [a, b])
      )
  end

  defp neighbours(contexts, members, excluded) do
    contexts
    |> Enum.reduce(MapSet.new(), &MapSet.union(&2, Map.get(members, &1, MapSet.new())))
    |> MapSet.difference(MapSet.new(excluded))
  end

  defp band_of(candidate, tenant) do
    case AshEnterprise.Mdm.Banding.band(candidate.score, tenant, banding_id: candidate.id) do
      {:ok, band} ->
        band

      {:error, {:no_published_baseline, _, _}} ->
        nil

      {:error, :no_platform_organization} ->
        nil

      {:error, reason} ->
        raise AshEnterprise.Mdm.MatchError, message: "banding failed: #{inspect(reason)}"
    end
  end

  # --- writes ----------------------------------------------------------------------

  defp set_candidate!(candidate, attrs, tenant) do
    system = SystemActor.system()

    candidate
    |> Ash.Changeset.for_update(:update, attrs, tenant: tenant, actor: system, authorize?: true)
    |> Ash.update!(tenant: tenant, actor: system, authorize?: true)
  end

  defp set_status!(staged, status, tenant) do
    staged
    |> Ash.Changeset.for_update(:update, %{status: status}, tenant: tenant, authorize?: false)
    |> Ash.update!(tenant: tenant, authorize?: false)

    status
  end

  # The observation's identity at `golden_id`: opened when new, left alone
  # when it already points there, repointed when it points elsewhere.
  defp ensure_identity!(staged, golden_id, asserted_by, confidence, tenant) do
    record = Ash.get!(SourceRecord, staged.source_record_id, authorize?: false)

    case SourceIdentity.current_for(record.source, record.stream, record.external_id,
           tenant: tenant,
           authorize?: false
         ) do
      {:ok, nil} ->
        SourceIdentity
        |> Ash.Changeset.for_create(
          :open,
          %{
            source: record.source,
            stream: record.stream,
            external_id: record.external_id,
            golden_resource: People.golden_resource(),
            golden_id: golden_id,
            asserted_by: asserted_by,
            confidence: confidence
          },
          tenant: tenant,
          authorize?: false
        )
        |> Ash.create!(tenant: tenant, authorize?: false)

      {:ok, %{golden_id: ^golden_id}} ->
        :ok

      {:ok, identity} ->
        identity
        |> Ash.Changeset.for_update(
          :repoint,
          %{golden_resource: People.golden_resource(), golden_id: golden_id},
          tenant: tenant,
          authorize?: false
        )
        |> Ash.update!(tenant: tenant, authorize?: false)
    end

    :ok
  end

  defp merge!(person, golden_id, tenant) do
    person
    |> Ash.Changeset.for_update(:mdm_merge_into, %{survivor_id: golden_id},
      tenant: tenant,
      authorize?: false
    )
    |> Ash.update!(tenant: tenant, authorize?: false)
  end

  @doc """
  A steward's confirm of a people pair (called from
  `AshEnterprise.Mdm.Changes.StewardVerdict` inside the confirm's
  transaction, after its person gate): the staged row's person folds into
  the candidate's golden, its identities and joins with it, and any other
  question still open about that person is moot.
  """
  def confirm!(candidate, staged, tenant) do
    case Ash.get(Person, staged.mapped["person_id"],
           tenant: tenant,
           authorize?: false,
           error?: false
         ) do
      {:ok, %Person{merged: false} = person} -> merge!(person, candidate.golden_id, tenant)
      _gone_or_already_merged -> :ok
    end

    set_status!(staged, :merged, tenant)
    supersede_open_questions!(staged, candidate, tenant)
    :ok
  end

  defp supersede_open_questions!(staged, decided, tenant) do
    staged_ids =
      StagedRecord
      |> Ash.Query.filter(mapped[:person_id] == ^staged.mapped["person_id"])
      |> Ash.Query.select([:id])
      |> Ash.read!(tenant: tenant, authorize?: false)
      |> Enum.map(& &1.id)

    MatchCandidate
    |> Ash.Query.filter(
      staged_record_id in ^staged_ids and status == :pending and id != ^decided.id
    )
    |> Ash.read!(tenant: tenant, authorize?: false)
    |> Enum.each(&set_candidate!(&1, %{status: :superseded}, tenant))
  end

  # --- process side ------------------------------------------------------------

  # The same stewardship process an import's review candidate starts
  # (`AshEnterprise.Mdm.BatchWorker`): resolved through the host resolver,
  # absent when the tenant runs no steward-review baseline.
  defp start_steward_review!(batch, candidate, tenant) do
    case AshEnterprise.Process.Resolver.resolve(:process, "mdm.steward_review", tenant) do
      {:ok, definition} ->
        AshBpmn.start_instance!(AshEnterprise.Bpmn,
          definition: definition,
          subject: candidate,
          actor: SystemActor.system(),
          tenant: tenant,
          correlation_id: batch.correlation_id
        )

      {:error, _reason} ->
        :ok
    end
  end

  defp lineage(event, batch) do
    opts = [run_id: batch.correlation_id, inputs: ["bizev:canonical.people"]]
    opts = if event == :fail, do: opts, else: Keyword.put(opts, :outputs, ["mdm_staged_records"])
    AshEnterprise.Lineage.ingestion_event(event, "mdm", "people:#{batch.id}", opts)
  end

  defp fail!(batch, reason) do
    # The exception's class only: an Ash error quotes the value it refused,
    # and here the values are people's names and addresses.
    batch
    |> Ash.Changeset.for_update(:fail, %{failure_reason: inspect(reason.__struct__)},
      tenant: batch.organization_id,
      authorize?: false
    )
    |> Ash.update!(tenant: batch.organization_id, authorize?: false)
  end
end
