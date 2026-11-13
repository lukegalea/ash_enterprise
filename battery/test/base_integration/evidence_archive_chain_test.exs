defmodule Battery.Integration.EvidenceArchiveChainTest do
  @moduledoc """
  Evidence archive ↔ audit chain: both halves of retention move old rows out of the hot
  tables, and nothing a reader relies on changes.

  An organization's audit log is hash-chained (`ash_events_chain`), and each day its chain's
  verification is recorded as evidence for a criterion (`ash_compliance`). Past the hot
  window, `AshEvents.Chain.Retention` moves the chain's old events to their archive and
  `AshCompliance.Ownership.Retention` moves the superseded evidence to the evidence
  archive, both by a verified copy, both recording into the one run ledger.

  Asserted: the chain verifies across the move, hot and archived together; the evidence
  for a past period, and the criterion's freshness at its end, read the same after the
  move as before it, now from the archive; the sweep's current answer is unchanged; and
  the ledger holds one verified run for each store.
  """

  use ExUnit.Case, async: false

  alias AshCompliance.Ownership.{Evidence, Package, Retention, Sweep}
  alias Battery.Audit.{ArchiveRun, EventLog}
  alias Battery.Repo

  @control "CC7.2"
  @producer "module:Battery.ChainVerification"

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    %{org: Ecto.UUID.generate(), now: DateTime.utc_now()}
  end

  test "evidence and the chain move to their archives, and neither reads differently",
       %{org: org, now: now} do
    # The chain: three events past the hot window, one inside it.
    for days <- [200, 150, 120], do: event!(org, days * 86_400)
    event!(org, 3_600)

    # The chain's daily verification, recorded as evidence: three past the hot window
    # (the last of them twelve hours before the period below ends) and today's.
    period_from = ago(now, 140 * 86_400)
    period_to = ago(now, 100 * 86_400)

    old =
      for seconds <- [130 * 86_400, 120 * 86_400, 100 * 86_400 + 43_200],
          do: verification!(org, ago(now, seconds), now)

    today = verification!(org, ago(now, 7_200), now)

    controls = controls_file!()
    before_period = sections!(org, period_from, period_to, controls, now)
    {:ok, before_sweep} = Sweep.run(org, controls_file: controls, now: now)
    assert %{findings: [], checked: 4} = AshEvents.Chain.verify(EventLog, org)

    # Both halves of retention, into one ledger.
    {:ok, audit_steps} =
      AshEvents.Chain.Retention.archive(EventLog, now: now, hot_days: 90)

    assert {:archived, %ArchiveRun{store: :battery_audit_events, status: :verified, row_count: 3}} =
             Enum.find(audit_steps, &match?({_, %{chain_organization_id: ^org}}, &1))

    assert {:ok, {:archived, %ArchiveRun{store: :evidence_artifacts, status: :verified}}} =
             Retention.archive(now: now, hot_days: 90, archive_run: ArchiveRun)

    # The chain verifies whole across the move: three archived events and the hot tail.
    assert %{findings: [], checked: 4} = AshEvents.Chain.verify(EventLog, org)
    assert hot_events(org) == 1

    # Every artifact is still read, each from where it now lives.
    {:ok, artifacts} = Evidence.for_control(org, @control)

    assert Enum.map(artifacts, &{&1.id, Evidence.location(&1)}) ==
             Enum.map(old, &{&1.id, :archive}) ++ [{today.id, :hot}]

    # The past period reads the same: its evidence, now archived, and the freshness at its
    # end, which rests on an archived artifact.
    after_period = sections!(org, period_from, period_to, controls, now)
    before_cc72 = criterion(before_period)
    after_cc72 = criterion(after_period)

    assert after_cc72["freshness"]["state"] == "evidenced"
    assert after_cc72["freshness"] == before_cc72["freshness"]

    assert after_cc72["freshness"]["latest_at"] ==
             DateTime.to_iso8601(List.last(old).collected_at)

    assert Enum.map(after_cc72["artifacts"], &Map.delete(&1, "location")) ==
             Enum.map(before_cc72["artifacts"], &Map.delete(&1, "location"))

    assert Enum.map(after_cc72["artifacts"], &{&1["location"], &1["integrity"]}) ==
             List.duplicate({"archive", "verified"}, 3)

    # The sweep's answer now is unchanged.
    {:ok, after_sweep} = Sweep.run(org, controls_file: controls, now: now)
    assert after_sweep == before_sweep
  end

  # --- helpers ---------------------------------------------------------------

  defp ago(now, seconds), do: DateTime.add(now, -seconds, :second)

  # An event in `org`'s chain, `seconds_ago` old. The chain trigger links and hashes it.
  defp event!(org, seconds_ago) do
    Repo.query!(
      "INSERT INTO battery_audit_events (record_id, metadata, occurred_at, resource, action, " <>
        "action_type) VALUES (gen_random_uuid(), $1::jsonb, " <>
        "now() - make_interval(secs => $2), 'Elixir.Probe', 'create', 'create')",
      [%{"organization_id" => org}, seconds_ago]
    )
  end

  defp hot_events(org) do
    [[n]] =
      Repo.query!("SELECT count(*) FROM battery_audit_events WHERE organization_id = $1::uuid", [
        Ecto.UUID.dump!(org)
      ]).rows

    n
  end

  # The chain's verification at `at`, recorded as evidence for the criterion.
  defp verification!(org, at, now) do
    content = Jason.encode!(%{"organization_id" => org, "verified_at" => at, "findings" => []})

    {:ok, artifact} =
      Evidence.record(org, @control, content,
        producer: @producer,
        media_type: "application/json",
        method: :test,
        collected_at: at,
        now: now
      )

    artifact
  end

  defp sections!(org, from, to, controls, now) do
    {:ok, sections} = Package.sections(org, from, to, controls_file: controls, generated_at: now)
    sections
  end

  defp criterion(sections), do: Enum.find(sections.evidence["criteria"], &(&1["id"] == @control))

  # A control file whose CC7.2 row is evidenced daily by the chain's verification.
  defp controls_file! do
    row = %{
      "id" => @control,
      "class" => "PLATFORM-EVIDENCED",
      "applicability" => "applicable",
      "frequency" => "daily",
      "owner_role" => "Head of Engineering",
      "evidence_producer" => @producer,
      "test_ref" => "file:test/base_integration/evidence_archive_chain_test.exs"
    }

    dir = Path.join(System.tmp_dir!(), "battery-controls-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "controls.json")
    File.write!(path, Jason.encode!(%{"frameworks" => ["soc2"], "criteria" => [row]}))
    on_exit(fn -> File.rm_rf!(dir) end)
    path
  end
end
