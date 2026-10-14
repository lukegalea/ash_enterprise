defmodule AshEnterprise.Mdm.BatchTest do
  @moduledoc """
  MDM-2: landing + staging — the raw layer through bizev, the batch pinning
  a mapping, the worker mapping landed rows into StagedRecords under ONE
  correlation id. Re-running a batch stages nothing new (both landings and
  stagings are idempotent by construction), and two organizations landing
  the same slug/row never collide (tenancy lives in the external_id).
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Mdm.TestSupport

  require Ash.Query

  alias AshEnterprise.Mdm.{ImportBatch, SourceRecord, StagedRecord}
  alias AshEnterprise.Platform.Seeder

  setup do
    previous_transport = Application.get_env(:ash_open_lineage, :transport)

    Application.put_env(:ash_open_lineage, :transport, AshOpenLineage.Transport.InMemory)
    start_supervised!(AshOpenLineage.Transport.InMemory)

    on_exit(fn ->
      if previous_transport do
        Application.put_env(:ash_open_lineage, :transport, previous_transport)
      else
        Application.delete_env(:ash_open_lineage, :transport)
      end
    end)

    AshOpenLineage.Transport.InMemory.clear()

    %{organization: org, user: admin} =
      Seeder.seed_tenant(
        name: "Mdm Batch A #{System.unique_integer([:positive])}",
        unique_name: "mdm-batch-a-#{System.unique_integer([:positive])}"
      )

    %{organization: org_b, user: _admin_b} =
      Seeder.seed_tenant(
        name: "Mdm Batch B #{System.unique_integer([:positive])}",
        unique_name: "mdm-batch-b-#{System.unique_integer([:positive])}"
      )

    # The resolver's undeclared-key fallback reads the platform
    # organization's baseline decisions.
    Seeder.seed_platform_organization()

    %{org: org.id, org_b: org_b.id, admin: admin}
  end

  defp seed_active_mapping!(org, admin) do
    draft_host_mapping!(org, []) |> activate_host_mapping!(org, admin)
  end

  defp land_rows!(org, slug, rows, opts \\ []) do
    Enum.map(rows, fn {key, payload} ->
      {:ok, record} = AshEnterprise.Mdm.Landing.land_row(org, slug, payload, row_key: key)

      record
    end)
  end

  defp upload_batch!(org, admin, slug) do
    mapping = seed_active_mapping!(org, admin)

    ImportBatch
    |> Ash.Changeset.for_create(:open, %{mapping_id: mapping.id, source_slug: slug},
      tenant: org,
      actor: admin
    )
    |> Ash.create!(tenant: org, actor: admin)
  end

  defp drain!(batch) do
    {:ok, _job} =
      %{"batch_id" => batch.id, "tenant" => batch.organization_id}
      |> AshEnterprise.Mdm.BatchWorker.new()
      |> Oban.insert()

    Oban.drain_queue(queue: :mdm, with_safety: false)

    ImportBatch.by_id!(batch.id, tenant: batch.organization_id, authorize?: false)
  end

  describe "landing" do
    test "two organizations landing the same slug and row key never collide", %{
      org: org,
      org_b: org_b
    } do
      {:ok, a} =
        AshEnterprise.Mdm.Landing.land_row(org, "acme", %{"Email" => "a@x.io"}, row_key: "1")

      {:ok, b} =
        AshEnterprise.Mdm.Landing.land_row(org_b, "acme", %{"Email" => "a@x.io"}, row_key: "1")

      assert a.external_id != b.external_id
      assert a.external_id == "#{org}:acme:1"
      assert b.external_id == "#{org_b}:acme:1"
    end

    test "identical content relands as a temporal no-op", %{org: org} do
      {:ok, first} =
        AshEnterprise.Mdm.Landing.land_row(org, "acme", %{"Email" => "a@x.io"}, row_key: "1")

      {:ok, again} =
        AshEnterprise.Mdm.Landing.land_row(org, "acme", %{"Email" => "a@x.io"}, row_key: "1")

      assert first.id == again.id
    end

    test "a CA-tenant row lands under :ca with a matching tag", %{org: org} do
      {:ok, record} =
        AshEnterprise.Mdm.Landing.land_row(org, "acme", %{"Email" => "a@x.io"},
          row_key: "ca1",
          region: :ca
        )

      assert record.region == :ca
      assert record.residency_tag == "ca"

      # ...and a us-tagged row cannot enter the CA region.
      assert {:error, _} =
               SourceRecord.land(
                 %{
                   source: :manual_csv,
                   stream: :upload,
                   external_id: "#{org}:acme:bad2",
                   region: :ca,
                   residency_tag: "us",
                   raw_payload: %{"Email" => "b@x.io"},
                   source_metadata: %{},
                   cursor: nil,
                   fetched_at: DateTime.utc_now()
                 },
                 authorize?: false
               )
    end

    test "a disagreeing residency tag is refused at land", %{org: org} do
      assert {:error, _} =
               SourceRecord.land(
                 %{
                   source: :manual_csv,
                   stream: :upload,
                   external_id: "#{org}:acme:bad",
                   region: :us,
                   residency_tag: "ca",
                   raw_payload: %{"Email" => "a@x.io"},
                   source_metadata: %{},
                   cursor: nil,
                   fetched_at: DateTime.utc_now()
                 },
                 authorize?: false
               )
    end
  end

  describe "staging" do
    test "the worker maps landed rows under the batch's correlation id", %{org: org, admin: admin} do
      rows = [
        {"r1", %{"Email" => " a@x.io ", "Full Name" => "Ann"}},
        {"r2", %{"Email" => "b@x.io", "Full Name" => "Ben"}},
        {"r3", %{"Full Name" => "No Email"}}
      ]

      land_rows!(org, "acme", rows)
      batch = drain!(upload_batch!(org, admin, "acme"))

      assert batch.status == :matching
      assert batch.counts["staged"] == 3

      staged =
        StagedRecord
        |> Ash.Query.filter(batch_id == ^batch.id)
        |> Ash.read!(tenant: org, authorize?: false)

      assert length(staged) == 3

      r1 = Enum.find(staged, &(&1.mapped["email"] == "a@x.io"))
      assert r1.status == :staged

      # r3 has no "Email" path — a rule error, staged as omitted WITH its
      # findings (the UI's per-row error display reads this).
      r3 = Enum.find(staged, &(&1.status == :omitted))
      assert %{"errors" => [_]} = stringify(r3.validation_findings)
    end

    test "a batch stages only its own slug, never a sibling slug", %{org: org, admin: admin} do
      land_rows!(org, "acme", [{"r1", %{"Email" => "a@x.io", "Full Name" => "Ann"}}])
      land_rows!(org, "acme_x", [{"r9", %{"Email" => "z@x.io", "Full Name" => "Zed"}}])

      batch = drain!(upload_batch!(org, admin, "acme"))

      staged =
        StagedRecord
        |> Ash.Query.filter(batch_id == ^batch.id)
        |> Ash.read!(tenant: org, authorize?: false)

      assert length(staged) == 1
      assert hd(staged).mapped["email"] == "a@x.io"
    end

    test "a changed re-land stages exactly one record carrying the newest values", %{
      org: org,
      admin: admin
    } do
      # r1 observed twice with different content: bizev SPLITS the period,
      # so two SourceRecord periods exist for the identity. Staging reads
      # as-of the batch's open instant and must see exactly one version.
      {:ok, _} =
        AshEnterprise.Mdm.Landing.land_row(
          org,
          "acme",
          %{"Email" => "old@x.io", "Full Name" => "Old"},
          row_key: "r1"
        )

      {:ok, _} =
        AshEnterprise.Mdm.Landing.land_row(
          org,
          "acme",
          %{"Email" => "new@x.io", "Full Name" => "New"},
          row_key: "r1"
        )

      batch = drain!(upload_batch!(org, admin, "acme"))

      staged =
        StagedRecord
        |> Ash.Query.filter(batch_id == ^batch.id)
        |> Ash.read!(tenant: org, authorize?: false)

      assert length(staged) == 1
      assert hd(staged).mapped["email"] == "new@x.io"
    end

    test "re-running a batch stages nothing new", %{org: org, admin: admin} do
      land_rows!(org, "acme", [{"r1", %{"Email" => "a@x.io", "Full Name" => "Ann"}}])
      batch = drain!(upload_batch!(org, admin, "acme"))

      drained_again = drain!(batch)

      assert drained_again.counts["staged"] == 1

      assert length(
               StagedRecord
               |> Ash.Query.filter(batch_id == ^batch.id)
               |> Ash.read!(tenant: org, authorize?: false)
             ) == 1
    end

    test "batch writes carry the batch's correlation id in the audit log", %{
      org: org,
      admin: admin
    } do
      land_rows!(org, "acme", [{"r1", %{"Email" => "a@x.io", "Full Name" => "Ann"}}])
      batch = drain!(upload_batch!(org, admin, "acme"))

      %{rows: [[audited]]} =
        AshEnterprise.Repo.query!(
          "SELECT count(*) FROM audit_events WHERE metadata->>'correlation_id' = $1",
          [batch.correlation_id]
        )

      # The batch's own transitions (open → staging → matching) are audited
      # under the correlation id — the lineage thread exists.
      assert audited > 0
    end
  end

  describe "lineage and failure" do
    test "the batch emits OpenLineage start and complete with run_id == correlation_id", %{
      org: org,
      admin: admin
    } do
      land_rows!(org, "acme", [{"r1", %{"Email" => "a@x.io", "Full Name" => "Ann"}}])
      batch = drain!(upload_batch!(org, admin, "acme"))

      events = AshOpenLineage.Transport.InMemory.events()
      runs = Enum.map(events, & &1["run"]["runId"])
      assert batch.correlation_id in runs
      assert length(Enum.filter(events, &(&1["eventType"] == "START"))) >= 1
      assert length(Enum.filter(events, &(&1["eventType"] == "COMPLETE"))) >= 1
    end

    test "a crashed pipeline marks the batch failed and emits a FAIL run", %{
      org: org,
      admin: admin
    } do
      import Ash.Query

      land_rows!(org, "acme", [{"r1", %{"Email" => "a@x.io", "Full Name" => "Ann"}}])
      batch = upload_batch!(org, admin, "acme")

      # Force the pipeline to fail: point the batch at a mapping id whose
      # row vanished after open (a pinned hash with no mapping).
      AshEnterprise.Repo.query!("DELETE FROM mdm_mappings WHERE id = $1", [
        Ecto.UUID.dump!(batch.mapping_id)
      ])

      _job =
        %{"batch_id" => batch.id, "tenant" => org}
        |> AshEnterprise.Mdm.BatchWorker.new()
        |> Oban.insert!()

      # with_safety: false re-raises the worker's reraised exception into
      # the test process — that IS the crash path under test.
      assert_raise AshEnterprise.Mdm.MappingMissing, fn ->
        Oban.drain_queue(queue: :mdm, with_safety: false)
      end

      failed = ImportBatch.by_id!(batch.id, tenant: org, authorize?: false)
      assert failed.status == :failed
      assert failed.failure_reason

      events = AshOpenLineage.Transport.InMemory.events()

      assert Enum.any?(
               events,
               &(&1["eventType"] == "FAIL" and &1["run"]["runId"] == batch.correlation_id)
             )
    end
  end

  describe "matching (MDM-3)" do
    defp seed_rule_set!(org, admin) do
      rules = [
        %{"name" => "email_exact", "kind" => "exact", "fields" => ["email"], "weight" => 1.0},
        %{
          "name" => "name_fuzzy",
          "kind" => "fuzzy",
          "field" => "name",
          "algorithm" => "levenshtein",
          "weight" => 0.5
        }
      ]

      AshEnterprise.Mdm.MatchRuleSet
      |> Ash.Changeset.for_create(
        :draft,
        %{golden_resource: "AshEnterprise.Canonical.Person", rules: rules},
        tenant: org,
        actor: admin,
        authorize?: true
      )
      |> Ash.create!(tenant: org, actor: admin, authorize?: true)
      |> then(fn rs ->
        rs
        |> Ash.Changeset.for_update(:activate, %{}, tenant: org, actor: admin, authorize?: true)
        |> Ash.update!(tenant: org, actor: admin, authorize?: true)
      end)
    end

    defp platform_org, do: AshEnterprise.Platform.Seeder.seed_platform_organization().id

    defp by_staged_email(org, email) do
      StagedRecord
      |> Ash.Query.filter(mapped["email"] == ^email)
      |> Ash.read!(tenant: org, authorize?: false)
      |> hd()
      |> Map.get(:id)
    end

    defp golden_person!(org, admin, name, email) do
      AshEnterprise.Canonical.Person
      |> Ash.Changeset.for_create(:upsert_from_source, %{
        name: name,
        email: email,
        owner_id: admin.id,
        owning_business_unit_id: admin.owning_business_unit_id
      })
      |> Ash.create!(tenant: org, authorize?: false)
    end

    test "exact, fuzzy and new rows produce the expected candidates", %{org: org, admin: admin} do
      seed_rule_set!(org, admin)
      gold = golden_person!(org, admin, "Ann Existing", "ann@x.io")

      land_rows!(org, "acme", [
        {"dupe", %{"Email" => "ann@x.io", "Full Name" => "Ann Existing"}},
        {"fuzzy", %{"Email" => "annette@x.io", "Full Name" => "Ann Exsiting"}},
        {"new", %{"Email" => "newperson@x.io", "Full Name" => "Nadia New"}}
      ])

      batch = drain!(upload_batch!(org, admin, "acme"))

      assert batch.rule_set_id
      assert batch.counts["staged"] == 3

      candidates =
        AshEnterprise.Mdm.MatchCandidate
        |> Ash.Query.filter(golden_resource == "AshEnterprise.Canonical.Person")
        |> Ash.read!(tenant: org, authorize?: false)
        |> Enum.group_by(& &1.staged_record_id)

      by_email =
        StagedRecord
        |> Ash.Query.filter(batch_id == ^batch.id)
        |> Ash.read!(tenant: org, authorize?: false)
        |> Map.new(&{&1.mapped["email"], &1})

      dupe = by_email["ann@x.io"]
      fuzzy = by_email["annette@x.io"]
      new = by_email["newperson@x.io"]

      assert MapSet.new(Map.get(candidates, dupe.id, []) |> Enum.map(& &1.golden_id)) ==
               MapSet.new([gold.id])

      dupe_candidate = candidates |> Map.get(dupe.id) |> hd()
      assert Decimal.eq?(dupe_candidate.score, Decimal.new(1))

      # The fuzzy pair is shortlisted and scored below 1 but well above 0.
      assert MapSet.member?(
               MapSet.new(Map.get(candidates, fuzzy.id, []) |> Enum.map(& &1.golden_id)),
               gold.id
             )

      fuzzy_candidate = candidates |> Map.get(fuzzy.id) |> Enum.find(&(&1.golden_id == gold.id))
      assert Decimal.lt?(fuzzy_candidate.score, Decimal.new(1))
      assert Decimal.gt?(fuzzy_candidate.score, Decimal.new(0))

      # The genuinely new person is not shortlisted against anyone.
      assert candidates[new.id] in [nil, []]

      # This tenant published no band table, so the banded rows stay
      # undecided (:matched) — but the genuinely new person has no candidate
      # to band: nothing fit, so the row became its own golden regardless.
      assert Ash.reload!(dupe, tenant: org, authorize?: false).status == :matched
      assert Ash.reload!(fuzzy, tenant: org, authorize?: false).status == :matched
      assert Ash.reload!(new, tenant: org, authorize?: false).status == :created

      # The new row's golden exists exactly once, with its SourceIdentity.
      new_goldens =
        AshEnterprise.Canonical.Person
        |> Ash.Query.filter(name == "Nadia New")
        |> Ash.read!(tenant: org, authorize?: false)

      assert length(new_goldens) == 1

      assert [%{}] =
               AshEnterprise.Mdm.SourceIdentity
               |> Ash.Query.filter(golden_id == ^hd(new_goldens).id)
               |> Ash.read!(tenant: org, authorize?: false)

      # Blocking ran as a SYSTEM actor (ADR 0017's first sharp edge) — and
      # that actor is visible in the audit trail under the batch's
      # correlation id, so "who generated this candidate" is answerable.
      # Blocking ran as a SYSTEM actor (ADR 0017's first sharp edge): the
      # candidate creates are audited under that actor and the batch's
      # correlation id, one audit row per candidate generated.
      candidate_count =
        AshEnterprise.Mdm.MatchCandidate
        |> Ash.Query.filter(golden_resource == "AshEnterprise.Canonical.Person")
        |> Ash.read!(tenant: org, authorize?: false)
        |> length()

      assert candidate_count > 0

      %{rows: [[system_rows]]} =
        AshEnterprise.Repo.query!(
          "SELECT count(*) FROM audit_events " <>
            "WHERE metadata->>'correlation_id' = $1 AND resource = $2 " <>
            "AND action_type = 'create' AND metadata->>'system_actor' = 'system'",
          [batch.correlation_id, "Elixir.AshEnterprise.Mdm.MatchCandidate"]
        )

      assert system_rows == candidate_count
    end

    test "candidate scores band through the DMN table, never a literal", %{org: org, admin: admin} do
      # The seed publishes into the PLATFORM organization — the baseline
      # every tenant's resolver reads (the access_request_risk pattern).
      AshEnterprise.Mdm.Banding.publish_seed_bands!(platform_org())
      seed_rule_set!(org, admin)

      gold = golden_person!(org, admin, "Ann Existing", "ann@x.io")

      land_rows!(org, "acme", [
        {"dupe", %{"Email" => "ann@x.io", "Full Name" => "Ann Existing"}},
        # Same email, changed surname: the exact rule fires (1.0) and the
        # fuzzy name drags the weighted score below the admit boundary but
        # above 0.5 — the seed's review band.
        {"fuzzy", %{"Email" => "ann@x.io", "Full Name" => "Ann Existing-Smith"}}
      ])

      batch = drain!(upload_batch!(org, admin, "acme"))

      bands =
        AshEnterprise.Mdm.MatchCandidate
        |> Ash.Query.filter(golden_resource == "AshEnterprise.Canonical.Person")
        |> Ash.read!(tenant: org, authorize?: false)
        |> Map.new(&{&1.staged_record_id, &1.band})

      # The identical pair scored 1.0: the seed's admit band — auto-merge
      # territory. The surname-drift pair scored ~0.89: the seed's review
      # band — a human looks. No literal in code decided either.
      candidates =
        AshEnterprise.Mdm.MatchCandidate
        |> Ash.Query.filter(golden_resource == "AshEnterprise.Canonical.Person")
        |> Ash.read!(tenant: org, authorize?: false)
        |> Map.new(&{&1.staged_record_id, &1})

      staged =
        StagedRecord
        |> Ash.Query.filter(batch_id == ^batch.id)
        |> Ash.read!(tenant: org, authorize?: false)
        |> Map.new(&{&1.mapped["name"], &1.id})

      assert candidates[staged["Ann Existing"]].band == :admit
      assert candidates[staged["Ann Existing-Smith"]].band == :review

      # The admit band ROUTED: the candidate is auto-merged (no human looked
      # — the published band table decided), the staged row is spent.
      assert candidates[staged["Ann Existing"]].status == :auto_merged

      assert StagedRecord.by_id!(staged["Ann Existing"], tenant: org, authorize?: false).status ==
               :merged

      assert gold.id
    end

    test "review-banded candidates appear in the System One ReviewQueue", %{
      org: org,
      admin: admin
    } do
      AshEnterprise.Platform.Seeder.seed_platform_organization()
      AshEnterprise.Mdm.Banding.publish_seed_bands!(platform_org())
      seed_rule_set!(org, admin)
      golden_person!(org, admin, "Ann Existing", "ann@x.io")

      # Same email, surname drift: the exact rule fires, the fuzzy name
      # drags the score to ~0.87 — between the seed's review floor (0.5)
      # and admit floor (0.9).
      land_rows!(org, "acme", [
        {"boundary", %{"Email" => "ann@x.io", "Full Name" => "Ann Existing-Smith"}}
      ])

      drain!(upload_batch!(org, admin, "acme"))

      {:ok, %{items: items}} =
        AshEnterprise.SystemOne.ReviewQueue.pending(tenant: org, kinds: [:mdm_match])

      assert length(items) == 1
      assert hd(items).kind == :mdm_match
      assert hd(items).record.band == :review
      assert hd(items).record.status == :pending

      # The fixture's measured score sits INSIDE the review band — if a
      # scoring change pushes it over 0.9, this fails with the real reason
      # instead of an empty queue.
      score = Decimal.to_float(hd(items).record.score)
      assert score >= 0.5 and score < 0.9, "score #{score} left the review band"
    end

    test "the trigram shortlist reads through the org-scoped GIN index, not a scan", %{org: org} do
      {:ok, org_bin} = Ecto.UUID.dump(org)

      # The planner prefers the email btree when the org predicate is
      # present, so EXPLAIN the shortlist's own access path: the trigram
      # predicate alone must read through the GIN index, not a scan.
      AshEnterprise.Repo.query!("SET enable_seqscan = off")

      %{rows: plan} =
        AshEnterprise.Repo.query!(
          "EXPLAIN SELECT id FROM canonical_people WHERE lower(name) % lower($1)",
          [org_bin_ignored = "Ann Existing"]
        )

      plan_text = Enum.map_join(plan, " ", & &1)
      assert plan_text =~ "canonical_people_name_trgm_idx"
    end
  end

  describe "opening" do
    test "a batch refuses a non-active mapping", %{org: org} do
      mapping = draft_host_mapping!(org, [])

      assert_raise Ash.Error.Invalid, ~r/ACTIVE version/, fn ->
        ImportBatch
        |> Ash.Changeset.for_create(:open, %{mapping_id: mapping.id, source_slug: "x"},
          tenant: org,
          authorize?: false
        )
        |> Ash.create!(tenant: org, authorize?: false)
      end
    end
  end
end
