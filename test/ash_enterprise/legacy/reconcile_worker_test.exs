defmodule AshEnterprise.Legacy.ReconcileWorkerTest do
  @moduledoc """
  The nightly reconcile of the projected legacy estate: drift between the legacy view and
  `projected_users` is found, reported as key ranges, and repaired through the one projection
  entry point; what the projection must not touch is left alone.
  """

  use AshEnterprise.DataCase, async: false

  import ExUnit.CaptureLog

  alias AshEnterprise.Accounts.ProjectedUser
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Compliance.EventLog, as: ComplianceLog
  alias AshEnterprise.Compliance.Seeds
  alias AshEnterprise.Legacy.Estate
  alias AshEnterprise.Legacy.ReconcileWorker
  alias AshEnterprise.Legacy.UserBackfill
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Repo

  setup ctx do
    case AshEnterprise.Platform.Seeder.seed_legacy_estate() do
      :already_seeded -> raise "the legacy estate should not survive the sandbox transaction"
      _seeded -> :ok
    end

    # The drain records the KYC compliance events of each row it projects, and refuses a row
    # when there is no active bundle to record them under; the repair does the same.
    unless ctx[:no_bundle], do: {:ok, _bundle} = Seeds.seed(Estate.organization_id())

    for row <- legacy_users(), do: :ok = UserBackfill.project_row(row)
    :ok
  end

  defp opts,
    do: [actor: SystemActor.projection(), tenant: Estate.organization_id(), authorize?: false]

  defp legacy_users do
    AshEnterprise.Legacy.User
    |> Ash.Query.for_read(:read, %{}, opts())
    |> Ash.read!(opts())
  end

  defp projected do
    ProjectedUser |> Ash.Query.for_read(:read, %{}, opts()) |> Ash.read!(opts())
  end

  defp insert_legacy_user!(login) do
    %Postgrex.Result{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO legacy.users (login, email, first_name, last_name, state, created_at, updated_at)
        VALUES ($1, $2, 'Recon', 'Cile', 'active', now(), now())
        RETURNING id
        """,
        [login, "#{login}@corp.example"]
      )

    id
  end

  defp projected_login(legacy_id) do
    %Postgrex.Result{rows: rows} =
      Repo.query!("SELECT login FROM projected_users WHERE legacy_id = $1 ORDER BY 1", [legacy_id])

    List.flatten(rows)
  end

  defp event_count, do: Ash.count!(EventLog, authorize?: false)

  # The KYC compliance events recorded for one legacy user by a reconcile repair.
  defp repair_events(legacy_id) do
    subject = Integer.to_string(legacy_id)

    ComplianceLog
    |> Ash.read!(authorize?: false)
    |> Enum.filter(fn event ->
      event.metadata["subject_id"] == subject and
        String.starts_with?(event.metadata["correlation_id"] || "", "reconcile:")
    end)
  end

  defp status_fact(event) do
    Enum.find_value(event.metadata["facts"], fn
      ["customer", "status", status] -> status
      _fact -> nil
    end)
  end

  @tag no_bundle: true
  test "a repair whose compliance events cannot be recorded is refused and left for the next run" do
    legacy_id = insert_legacy_user!("no.bundle")

    report = ReconcileWorker.run()

    assert report.refused >= 1
    refute report.converged?
    assert projected_login(legacy_id) == []
    assert repair_events(legacy_id) == []
  end

  test "a repaired row's compliance events are recorded as the drain records them" do
    victim = Enum.find(projected(), &(&1.login == "awhitfield"))
    assert repair_events(victim.legacy_id) == []

    # The legacy application suspends the user; the ledger event is never drained.
    Repo.query!("UPDATE legacy.users SET state = 'suspended' WHERE id = $1", [victim.legacy_id])

    report = ReconcileWorker.run()
    assert report.converged?

    projected = Enum.find(projected(), &(&1.legacy_id == victim.legacy_id))
    assert projected.legacy_state == "suspended"

    events = repair_events(victim.legacy_id)
    assert events != []
    assert Enum.all?(events, &(status_fact(&1) == "suspended"))

    # A legacy user the drain never saw is evaluated too, not left unevaluated.
    missed = insert_legacy_user!("missed.compliance")
    assert %{converged?: true} = ReconcileWorker.run()
    assert [_ | _] = missed_events = repair_events(missed)
    assert Enum.all?(missed_events, &(status_fact(&1) == "active"))
  end

  test "a projected row that disagrees with its legacy row is reported by key range, repaired, and the estate converges" do
    victim = Enum.find(projected(), &(&1.login == "awhitfield"))

    Repo.query!("UPDATE projected_users SET login = 'tampered' WHERE legacy_id = $1", [
      victim.legacy_id
    ])

    report = ReconcileWorker.run(repair?: false)
    refute report.projection_agrees?
    refute report.converged?

    assert Enum.any?(report.mismatched_ranges, fn {lo, hi} ->
             lo <= victim.legacy_id and victim.legacy_id <= hi
           end)

    assert projected_login(victim.legacy_id) == ["tampered"]

    report = ReconcileWorker.run()
    refute report.projection_agrees?
    assert report.repaired > 0
    assert report.converged?
    assert projected_login(victim.legacy_id) == ["awhitfield"]

    assert %{projection_agrees?: true, view_agrees?: true, mismatched_ranges: []} =
             ReconcileWorker.run()
  end

  test "a legacy row with no projected row (a missed ledger event) is found and projected" do
    legacy_id = insert_legacy_user!("missed.event")
    assert projected_login(legacy_id) == []

    report = ReconcileWorker.run()

    refute report.projection_agrees?

    assert Enum.any?(report.mismatched_ranges, fn {lo, hi} ->
             lo <= legacy_id and legacy_id <= hi
           end)

    assert report.converged?
    assert projected_login(legacy_id) == ["missed.event"]
  end

  test "a projected row whose legacy row was hard-deleted is reported and left in place" do
    legacy_id = insert_legacy_user!("gone.for.good")
    assert %{converged?: true} = ReconcileWorker.run()
    assert projected_login(legacy_id) == ["gone.for.good"]

    Repo.query!("DELETE FROM legacy.users WHERE id = $1", [legacy_id])

    report = ReconcileWorker.run()

    assert report.orphaned == %{count: 1, keys: [legacy_id]}
    assert projected_login(legacy_id) == ["gone.for.good"]
  end

  test "projected rows of another organization are neither compared nor touched" do
    other_org = Ecto.UUID.generate()
    legacy_id = insert_legacy_user!("shared.key")
    estate_before = length(projected())

    # `ProjectedUser.project` forces the estate's organization, so the other tenant's row is
    # seeded by SQL. It reuses a legacy key the estate has not projected yet, and carries a
    # login the legacy row does not.
    Repo.query!(
      """
      INSERT INTO projected_users
        (id, organization_id, legacy_id, login, email, full_name, legacy_state, projected_at)
      VALUES (gen_random_uuid(), $1, $2, 'other.tenant', 'x@other.example', 'Other', 'active', now())
      """,
      [Ecto.UUID.dump!(other_org), legacy_id]
    )

    report = ReconcileWorker.run()

    assert report.converged?
    assert report.orphaned.count == 0
    assert length(projected()) == estate_before + 1
    assert Enum.sort(projected_login(legacy_id)) == ["other.tenant", "shared.key"]

    %Postgrex.Result{rows: [[login]]} =
      Repo.query!("SELECT login FROM projected_users WHERE organization_id = $1", [
        Ecto.UUID.dump!(other_org)
      ])

    assert login == "other.tenant"
  end

  test "an estate that agrees reports agrees? and writes nothing" do
    before_rows = Map.new(projected(), &{&1.legacy_id, &1.projected_at})
    before_events = event_count()

    report = ReconcileWorker.run()

    assert %{
             view_agrees?: true,
             projection_agrees?: true,
             converged?: true,
             mismatched_ranges: [],
             repaired: 0,
             refused: 0
           } = report

    assert Map.new(projected(), &{&1.legacy_id, &1.projected_at}) == before_rows
    assert event_count() == before_events
  end

  test "the report carries counts and key ranges only, no names or emails" do
    victim = Enum.find(projected(), &(&1.login == "awhitfield"))

    Repo.query!("UPDATE projected_users SET login = 'tampered' WHERE legacy_id = $1", [
      victim.legacy_id
    ])

    handler = "reconcile-report-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:ash_enterprise, :legacy, :reconcile],
      fn _event, measurements, metadata, _ ->
        send(test_pid, {:reconcile, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    # The suite runs at :warning; the report is an :info line.
    Logger.put_module_level(ReconcileWorker, :info)
    on_exit(fn -> Logger.delete_module_level(ReconcileWorker) end)

    log = capture_log([level: :info], fn -> ReconcileWorker.run() end)

    assert_received {:reconcile, measurements, metadata}
    assert measurements.mismatched >= 1 and measurements.repaired >= 1
    assert metadata.converged?

    forbidden =
      Enum.flat_map(legacy_users(), &[&1.login, to_string(&1.email), &1.full_name]) ++
        ["tampered"]

    rendered = log <> inspect(measurements) <> inspect(metadata)

    for value <- forbidden, is_binary(value), value != "" do
      refute rendered =~ value, "the report leaks #{inspect(value)}"
    end

    assert log =~ "legacy reconcile:"
  end

  test "the reconcile worker is on the crontab on its queue" do
    crontab =
      :ash_enterprise
      |> Application.fetch_env!(Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find_value(fn
        {Oban.Plugins.Cron, opts} -> opts[:crontab]
        _ -> nil
      end)

    assert {"23 3 * * *", ReconcileWorker, entry_opts} =
             Enum.find(crontab, &(elem(&1, 1) == ReconcileWorker))

    assert entry_opts[:queue] == :ash_strangler_ledger
    assert ReconcileWorker.__opts__()[:queue] == :ash_strangler_ledger
  end
end
