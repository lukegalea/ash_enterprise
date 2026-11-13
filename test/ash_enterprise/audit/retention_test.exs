defmodule AshEnterprise.Audit.RetentionTest do
  @moduledoc """
  Ninety days hot, archived with a verified copy, never purged before four hundred days
  (ADR 0024's age half, `AshEnterprise.Audit.Retention`).

  The refusals come first: what the database will not delete, what a failed verification
  leaves in place, and what a purge will never reach. Then the moves that do happen, and
  that the chain still verifies across hot, archived and purged rows.
  """

  use AshEnterprise.DataCase, async: false

  alias AshCompliance.Ownership.Evidence
  alias AshEnterprise.Audit.{ArchiveRun, EventLog, Retention}
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

    test "a purge past four hundred days removes archived evidence, recorded", ctx do
      for days <- [500, 450], do: artifact!(ctx.org, days, "old #{days}")
      artifact!(ctx.org, 1, "newest")
      {:ok, %{evidence: {:archived, _}}} = Retention.archive()

      {:ok, %{evidence: step}} = Retention.purge(days: 400)

      assert {:purged, %ArchiveRun{store: :evidence_artifacts, kind: :purge, row_count: 2}} =
               step

      assert {:ok, [%{content: "newest"}]} = Evidence.for_control(ctx.org, "CC4.1")
    end
  end
end
