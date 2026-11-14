defmodule AshEnterprise.Audit.RetentionTest do
  @moduledoc """
  Ninety days hot, archived with a verified copy, never purged before four hundred days
  (ADR 0024's age half, `AshEnterprise.Audit.Retention`).

  The refusals come first: what the database will not delete, what a failed verification
  leaves in place, and what a purge will never reach. Then the moves that do happen, and
  that the chain still verifies across hot, archived and purged rows.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshCompliance.Ownership.Evidence
  alias AshEnterprise.Audit.{ArchiveRun, ChainVerifyWorker, EventLog, Retention, RetentionWorker}
  alias AshEnterprise.Repo

  setup do
    %{org: Ash.UUID.generate()}
  end

  # An event in `org`'s chain, `days_ago` old. The chain trigger hashes and links it.
  defp event!(org, days_ago) do
    [[id]] =
      Repo.query!(
        "INSERT INTO audit_events (record_id, metadata, occurred_at, resource, action, action_type) " <>
          "VALUES (gen_random_uuid(), $1::jsonb, now() - make_interval(days => $2), " <>
          "'Elixir.Probe', 'create', 'create') RETURNING id",
        [%{"organization_id" => org}, days_ago]
      ).rows

    Ecto.UUID.cast!(id)
  end

  defp hot_count(org), do: count("audit_events", org)
  defp archived_count(org), do: count("audit_event_archive", org)

  defp count(table, org) do
    [[n]] =
      Repo.query!("SELECT count(*) FROM #{table} WHERE organization_id = $1::uuid", [
        Ecto.UUID.dump!(org)
      ]).rows

    n
  end

  # Copies one hot row to the archive as it is, optionally with `data` changed.
  defp plant_copy!(id, data \\ nil) do
    Repo.query!(
      """
      INSERT INTO audit_event_archive
        (id, sequence, organization_id, record_id, version, occurred_at, resource, action,
         action_type, user_id, data, changed_attributes, metadata, previous_hash, hash,
         archived_at)
      SELECT id, sequence, organization_id, record_id, version, occurred_at, resource, action,
             action_type, user_id, coalesce($2::jsonb, data), changed_attributes, metadata,
             previous_hash, hash, now()
      FROM audit_events WHERE id = $1::uuid
      """,
      [Ecto.UUID.dump!(id), data]
    )
  end

  # Sets the action of `org`'s first event behind the immutability trigger's back, which the
  # chain's hash catches.
  defp quietly_change_first!(org, action) do
    Repo.query!("ALTER TABLE audit_events DISABLE TRIGGER audit_events_immutable")

    try do
      Repo.query!(
        "UPDATE audit_events SET action = $2 WHERE organization_id = $1::uuid " <>
          "AND sequence = (SELECT min(sequence) FROM audit_events WHERE organization_id = $1::uuid)",
        [Ecto.UUID.dump!(org), action]
      )
    after
      Repo.query!("ALTER TABLE audit_events ENABLE TRIGGER audit_events_immutable")
    end
  end

  defp chain_findings(org) do
    org
    |> AshCompliance.Domain.findings_for_organization!(authorize?: false)
    |> Enum.filter(&(&1.subject_type == ChainVerifyWorker.subject_type()))
  end

  defp step_for(%{audit: steps}, org) do
    Enum.find(steps, fn
      {_, %ArchiveRun{chain_organization_id: ^org}} -> true
      _ -> false
    end) || :nothing
  end

  describe "the hot log refuses a delete" do
    test "of a row with no archived copy", ctx do
      id = event!(ctx.org, 120)

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.query!("DELETE FROM audit_events WHERE id = $1::uuid", [Ecto.UUID.dump!(id)])
      end
    end

    test "of a row whose archived copy differs from it", ctx do
      id = event!(ctx.org, 120)
      plant_copy!(id, %{"tampered" => true})

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.query!("DELETE FROM audit_events WHERE id = $1::uuid", [Ecto.UUID.dump!(id)])
      end
    end

    # The immutability trigger compares every copied column, the temporal ones included
    # (priv/repo/migrations/20261113091903_s7_audit_chain_on_package.exs).
    test "of a row whose archived copy differs only in as_of", ctx do
      id = event!(ctx.org, 120)
      plant_copy!(id)

      Repo.query!("ALTER TABLE audit_event_archive DISABLE TRIGGER USER")

      try do
        Repo.query!("UPDATE audit_event_archive SET as_of = now() WHERE id = $1::uuid", [
          Ecto.UUID.dump!(id)
        ])
      after
        Repo.query!("ALTER TABLE audit_event_archive ENABLE TRIGGER USER")
      end

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.query!("DELETE FROM audit_events WHERE id = $1::uuid", [Ecto.UUID.dump!(id)])
      end
    end

    test "of a row younger than ninety days, even with an identical copy", ctx do
      id = event!(ctx.org, 89)
      plant_copy!(id)

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.query!("DELETE FROM audit_events WHERE id = $1::uuid", [Ecto.UUID.dump!(id)])
      end
    end
  end

  describe "archive refuses" do
    test "a hot window under ninety days, and moves nothing", ctx do
      event!(ctx.org, 200)
      event!(ctx.org, 1)

      assert {:error, {:below_floor, :hot_days, 90}} = Retention.archive(hot_days: 89)
      assert hot_count(ctx.org) == 2
      assert archived_count(ctx.org) == 0
    end

    test "a failed verify deletes nothing", ctx do
      [first | _] = for days <- [200, 150, 120], do: event!(ctx.org, days)
      event!(ctx.org, 1)

      # A copy already in the archive that differs from the hot row: the move's insert
      # leaves it (ON CONFLICT DO NOTHING), and the comparison must catch it.
      plant_copy!(first, %{"tampered" => true})

      {:ok, result} = Retention.archive()

      assert {:failed, %ArchiveRun{status: :failed, reason: reason, kind: :archive}} =
               step_for(result, ctx.org)

      # The chain verifier sees the second, different row at that position first; the
      # copy comparison would refuse it too. Either way the move stops before any delete.
      assert reason =~ ~r/finding|differ/
      # Every hot row is still there, and nothing new reached the archive.
      assert hot_count(ctx.org) == 4
      assert archived_count(ctx.org) == 1
    end

    test "one tenant with a broken chain does not stop another tenant's archive or verification",
         ctx do
      broken = Ash.UUID.generate()

      for org <- [ctx.org, broken] do
        for days <- [200, 150], do: event!(org, days)
        event!(org, 1)
      end

      verifier = fn log, partition ->
        if partition == broken, do: raise("the chain could not be read")
        AshEvents.Chain.verify(log, partition)
      end

      {:ok, result} = Retention.archive(verifier: verifier)

      assert {:failed, %ArchiveRun{status: :failed, row_count: 0, reason: reason}} =
               step_for(result, broken)

      assert reason =~ "the chain could not be read"
      assert hot_count(broken) == 3
      assert archived_count(broken) == 0

      assert {:archived, %ArchiveRun{status: :verified, row_count: 2}} =
               step_for(result, ctx.org)

      assert archived_count(ctx.org) == 2

      # The daily verification: evidence for the healthy tenant, an error finding for the
      # broken one, and no evidence that would read as the control operating there.
      assert {:ok, outcomes} = ChainVerifyWorker.run(verifier: verifier)
      assert {ctx.org, 0} in outcomes
      assert {broken, {:error, "the chain could not be read"}} in outcomes

      for control <- ChainVerifyWorker.evidence_controls() do
        assert [_] =
                 AshCompliance.Domain.evidence_for_control!(ctx.org, control, authorize?: false)

        assert [] = AshCompliance.Domain.evidence_for_control!(broken, control, authorize?: false)
      end

      findings =
        broken
        |> AshCompliance.Domain.findings_for_organization!(authorize?: false)
        |> Enum.filter(&(&1.subject_type == ChainVerifyWorker.subject_type()))

      assert Enum.sort(Enum.map(findings, & &1.control_id)) ==
               Enum.sort(ChainVerifyWorker.evidence_controls())

      assert Enum.all?(findings, &(&1.status == :error and is_nil(&1.resolved_at)))
      assert Enum.all?(findings, &(&1.explanation =~ "the chain could not be read"))

      assert [] =
               ctx.org
               |> AshCompliance.Domain.findings_for_organization!(authorize?: false)
               |> Enum.filter(&(&1.subject_type == ChainVerifyWorker.subject_type()))

      # Read cleanly the next day, the broken tenant's findings are resolved.
      assert {:ok, again} = ChainVerifyWorker.run()
      assert {broken, 0} in again

      assert broken
             |> AshCompliance.Domain.findings_for_organization!(authorize?: false)
             |> Enum.filter(&(&1.subject_type == ChainVerifyWorker.subject_type()))
             |> Enum.all?(&match?(%DateTime{}, &1.resolved_at))
    end

    test "a chain read with breaks keeps its finding open, and a break opens one", ctx do
      once_unreadable = ctx.org
      first_broken = Ash.UUID.generate()

      for org <- [once_unreadable, first_broken] do
        for days <- [200, 150], do: event!(org, days)
        event!(org, 1)
      end

      raising = fn log, partition ->
        if partition == once_unreadable, do: raise("the chain could not be read")
        AshEvents.Chain.verify(log, partition)
      end

      assert {:ok, _} = ChainVerifyWorker.run(verifier: raising)
      assert Enum.all?(chain_findings(once_unreadable), &(&1.status == :error))

      for org <- [once_unreadable, first_broken], do: quietly_change_first!(org, "tampered")

      assert {:ok, outcomes} = ChainVerifyWorker.run()

      for org <- [once_unreadable, first_broken] do
        assert {^org, breaks} = List.keyfind(outcomes, org, 0)
        assert breaks > 0

        findings = chain_findings(org)

        assert Enum.sort(Enum.map(findings, & &1.control_id)) ==
                 Enum.sort(ChainVerifyWorker.evidence_controls())

        # Read with breaks is not "verified again": the finding stays open, and says why.
        assert Enum.all?(findings, &is_nil(&1.resolved_at))
        assert Enum.all?(findings, &(&1.status == :noncompliant and &1.severity == :critical))
        assert Enum.all?(findings, &(&1.explanation =~ "fail verification"))
      end

      # Put back, the chain verifies cleanly, and only then are the findings resolved.
      for org <- [once_unreadable, first_broken], do: quietly_change_first!(org, "create")

      assert {:ok, clean} = ChainVerifyWorker.run()

      for org <- [once_unreadable, first_broken] do
        assert {org, 0} in clean
        assert Enum.all?(chain_findings(org), &match?(%DateTime{}, &1.resolved_at))
      end
    end

    test "a chain with a verification finding, and moves nothing", ctx do
      for days <- [200, 150], do: event!(ctx.org, days)
      event!(ctx.org, 1)

      Repo.query!("ALTER TABLE audit_events DISABLE TRIGGER audit_events_immutable")

      try do
        Repo.query!(
          "UPDATE audit_events SET action = 'quietly_changed' WHERE organization_id = $1::uuid " <>
            "AND sequence = (SELECT min(sequence) FROM audit_events WHERE organization_id = $1::uuid)",
          [Ecto.UUID.dump!(ctx.org)]
        )
      after
        Repo.query!("ALTER TABLE audit_events ENABLE TRIGGER audit_events_immutable")
      end

      {:ok, result} = Retention.archive()

      assert {:failed, %ArchiveRun{reason: reason}} = step_for(result, ctx.org)
      assert reason =~ "finding"
      assert hot_count(ctx.org) == 3
      assert archived_count(ctx.org) == 0
    end
  end

  describe "archive moves" do
    test "the old run of a chain, verified, and the chain still verifies", ctx do
      for days <- [200, 150, 120], do: event!(ctx.org, days)
      for days <- [30, 1], do: event!(ctx.org, days)

      {:ok, result} = Retention.archive()

      assert {:archived, %ArchiveRun{} = run} = step_for(result, ctx.org)
      assert run.status == :verified
      assert run.row_count == 3
      assert is_binary(run.digest) and byte_size(run.digest) == 64

      assert hot_count(ctx.org) == 2
      assert archived_count(ctx.org) == 3

      assert %{findings: [], checked: 5} = AshEvents.Chain.verify(EventLog, ctx.org)

      # Archived rows read back through Ash like the log does.
      assert length(AshEnterprise.Audit.archived_chain!(ctx.org, authorize?: false)) == 3
    end

    test "never the tail of a chain, so the next event still links to it", ctx do
      for days <- [300, 200, 100], do: event!(ctx.org, days)

      {:ok, result} = Retention.archive()
      assert {:archived, %ArchiveRun{row_count: 2}} = step_for(result, ctx.org)
      assert hot_count(ctx.org) == 1

      event!(ctx.org, 0)
      assert %{findings: [], checked: 4} = AshEvents.Chain.verify(EventLog, ctx.org)
    end

    test "nothing on a second run", ctx do
      for days <- [200, 1], do: event!(ctx.org, days)

      {:ok, _} = Retention.archive()
      {:ok, again} = Retention.archive()

      assert step_for(again, ctx.org) == :nothing
    end

    test "a backlog over the daily cap is reported", ctx do
      for days <- [300, 250, 200, 150, 120], do: event!(ctx.org, days)
      event!(ctx.org, 1)

      ref = :telemetry_test.attach_event_handlers(self(), [RetentionWorker.event()])
      on_exit(fn -> :telemetry.detach(ref) end)

      assert {:ok, %{backlog: %{archive: 3, purge: 0}, archived: %{archived: 1}}} =
               RetentionWorker.run(batch_size: 2, max_batches: 1)

      assert_received {[:ash_enterprise, :audit, :retention], ^ref, %{backlog: 3, failed: 0}, _}

      assert hot_count(ctx.org) == 4
      assert archived_count(ctx.org) == 2

      [run] =
        ArchiveRun
        |> Ash.Query.filter(chain_organization_id == ^ctx.org)
        |> Ash.read!(authorize?: false)

      assert run.status == :verified
      assert run.reason =~ "3 eligible row(s) remain"

      # Within a run's bound, the next run drains it.
      assert {:ok, %{backlog: %{archive: 0}}} = RetentionWorker.run(batch_size: 2, max_batches: 2)
      assert hot_count(ctx.org) == 1
      assert %{findings: [], checked: 6} = AshEvents.Chain.verify(EventLog, ctx.org)
    end

    test "nothing younger than the hot window", ctx do
      for days <- [80, 40, 1], do: event!(ctx.org, days)

      {:ok, result} = Retention.archive()

      assert step_for(result, ctx.org) == :nothing
      assert hot_count(ctx.org) == 3
    end
  end

  describe "purge" do
    test "never runs unless a number is configured" do
      assert Retention.purge_after_days() == nil
      assert {:ok, :disabled} = Retention.purge()
    end

    test "refuses fewer than four hundred days, and deletes nothing", ctx do
      for days <- [500, 450], do: event!(ctx.org, days)
      event!(ctx.org, 1)
      {:ok, _} = Retention.archive()

      assert {:error, {:below_floor, :purge_after_days, 400}} = Retention.purge(days: 399)
      assert archived_count(ctx.org) == 2
    end

    test "a 399-day row is never purged", ctx do
      for days <- [401, 399], do: event!(ctx.org, days)
      event!(ctx.org, 1)
      {:ok, _} = Retention.archive()
      assert archived_count(ctx.org) == 2

      {:ok, result} = Retention.purge(days: 400)

      assert {:purged, %ArchiveRun{kind: :purge, row_count: 1, tail_hash: tail}} =
               step_for(result, ctx.org)

      assert is_binary(tail)
      assert archived_count(ctx.org) == 1

      [[remaining]] =
        Repo.query!(
          "SELECT occurred_at > now() - interval '400 days' FROM audit_event_archive " <>
            "WHERE organization_id = $1::uuid",
          [Ecto.UUID.dump!(ctx.org)]
        ).rows

      assert remaining

      # And the database refuses it whoever asks.
      assert_raise Postgrex.Error, ~r/400 days/, fn ->
        Repo.query!("DELETE FROM audit_event_archive WHERE organization_id = $1::uuid", [
          Ecto.UUID.dump!(ctx.org)
        ])
      end

      # What remains verifies from the purge's anchor.
      assert %{findings: [], checked: 2, anchored_after: anchored} =
               AshEvents.Chain.verify(EventLog, ctx.org)

      assert is_integer(anchored)
    end

    test "the archive refuses every update", ctx do
      event!(ctx.org, 500)
      event!(ctx.org, 1)
      {:ok, _} = Retention.archive()

      assert_raise Postgrex.Error, ~r/400 days/, fn ->
        Repo.query!(
          "UPDATE audit_event_archive SET action = 'x' WHERE organization_id = $1::uuid",
          [Ecto.UUID.dump!(ctx.org)]
        )
      end
    end
  end

  describe "evidence" do
    defp artifact!(org, days_ago, content) do
      now = DateTime.utc_now()

      {:ok, artifact} =
        Evidence.record(org, "CC4.1", content,
          producer: "module:Probe",
          collected_at: DateTime.add(now, -days_ago * 86_400, :second),
          now: now,
          authorize?: false
        )

      artifact
    end

    defp hot_artifacts(org) do
      [[n]] =
        Repo.query!(
          "SELECT count(*) FROM ash_compliance_evidence_artifacts WHERE organization_id = $1::uuid",
          [Ecto.UUID.dump!(org)]
        ).rows

      n
    end

    test "a failed verify deletes nothing", ctx do
      old = artifact!(ctx.org, 200, "old")
      artifact!(ctx.org, 1, "new")

      Repo.query!(
        """
        INSERT INTO evidence_artifact_archive
          (id, organization_id, control_id, hash, content, media_type, collector, method,
           chain_of_custody, collected_at, inserted_at, archived_at)
        SELECT id, organization_id, control_id, hash, 'not the bytes', media_type, collector,
               method, chain_of_custody, collected_at, inserted_at, now()
        FROM ash_compliance_evidence_artifacts WHERE id = $1::uuid
        """,
        [Ecto.UUID.dump!(old.id)]
      )

      {:ok, %{evidence: step}} = Retention.archive()

      assert {:failed, %ArchiveRun{store: :evidence_artifacts, status: :failed}} = step
      assert hot_artifacts(ctx.org) == 2
    end

    test "the newest artifact of a control stays hot whatever its age", ctx do
      artifact!(ctx.org, 300, "only one")

      {:ok, %{evidence: step}} = Retention.archive()

      assert step == :nothing
      assert hot_artifacts(ctx.org) == 1
    end

    test "older artifacts past ninety days move, verified", ctx do
      for days <- [300, 200], do: artifact!(ctx.org, days, "old #{days}")
      artifact!(ctx.org, 100, "newest")

      {:ok, %{evidence: step}} = Retention.archive()

      assert {:archived, %ArchiveRun{status: :verified, row_count: 2}} = step
      assert hot_artifacts(ctx.org) == 1

      # A read of evidence for the control takes the hot table and the archive together,
      # so the move changes nothing a reader sees.
      {:ok, all} = Evidence.for_control(ctx.org, "CC4.1")

      assert Enum.map(all, &{&1.content, Evidence.location(&1)}) == [
               {"old 300", :archive},
               {"old 200", :archive},
               {"newest", :hot}
             ]

      assert Enum.all?(all, &(Evidence.verify(&1) == :ok))
    end

    test "the archive is ash_compliance's, named in configuration" do
      assert AshCompliance.Resources.evidence_archive?(AshEnterprise.Audit.ArchivedEvidence)

      assert AshCompliance.Ownership.Retention.configured_archive() ==
               AshEnterprise.Audit.ArchivedEvidence
    end

    # `inserted_at` is set when an artifact is recorded and no caller can set it; here the
    # artifact is made to have been recorded `days_ago` days ago.
    defp recorded!(artifact, days_ago) do
      Repo.query!(
        "UPDATE ash_compliance_evidence_artifacts SET inserted_at = now() - make_interval(days => $2) " <>
          "WHERE id = $1::uuid",
        [Ecto.UUID.dump!(artifact.id), days_ago]
      )

      artifact
    end

    test "a back-dated artifact is kept four hundred days from when it was recorded", ctx do
      # Its collector says 500 days ago; it was recorded today.
      artifact!(ctx.org, 500, "back-dated")
      artifact!(ctx.org, 1, "newest")
      {:ok, %{evidence: {:archived, _}}} = Retention.archive()

      {:ok, %{evidence: step}} = Retention.purge(days: 400)
      assert step == :nothing

      assert_raise Postgrex.Error, ~r/400 days/, fn ->
        Repo.query!(
          "DELETE FROM evidence_artifact_archive WHERE organization_id = $1::uuid",
          [Ecto.UUID.dump!(ctx.org)]
        )
      end

      assert {:ok, [%{content: "back-dated"}, %{content: "newest"}]} =
               Evidence.for_control(ctx.org, "CC4.1")
    end

    test "a purge past four hundred days removes archived evidence, recorded", ctx do
      for days <- [500, 450], do: ctx.org |> artifact!(days, "old #{days}") |> recorded!(days)
      artifact!(ctx.org, 1, "newest")
      {:ok, %{evidence: {:archived, _}}} = Retention.archive()

      {:ok, %{evidence: step}} = Retention.purge(days: 400)

      assert {:purged, %ArchiveRun{store: :evidence_artifacts, kind: :purge, row_count: 2}} =
               step

      assert {:ok, [%{content: "newest"}]} = Evidence.for_control(ctx.org, "CC4.1")
    end
  end
end
