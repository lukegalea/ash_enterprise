defmodule AshEnterprise.Legacy.ReconcileWorker do
  @moduledoc """
  The nightly check that the estate projected into `projected_users` still agrees with the
  legacy application's rows, and the repair when it does not.

  The live path is the change ledger's drain (`AshEnterprise.Ledger.UserDrainWorker`), which is
  at-least-once and swept every five minutes. This is the audit of that path: a drain that
  ingested the wrong thing, a row that failed to project, a projected row edited by hand. It
  compares, in the database, whole batches of rows by checksum, so the answer to "where is the
  drift" is a key range and never "somewhere in the table".

  ## Two comparisons

    1. `AshStrangler.Reconciler.diff(AshEnterprise.Legacy.User)`: the legacy table against the
       compatibility view. It catches a stale view or twin, and says nothing about the projection.
    2. The view against `projected_users`, restricted to the estate's organization. This is the
       drift the projection can have, and the one the repair acts on.

  ## What is compared, and what is not

    * Archived rows (the legacy application's `deleted_at`) are outside the projection by the read
      model's own rule, so they are neither compared nor repaired, whichever side holds them.
    * Projected rows of any other organization are never read: the projected side is filtered to
      `Legacy.Estate.organization_id/0`.
    * A projected row whose legacy row no longer exists is **reported and never deleted**. The
      ledger's ingestion skips a hard `DELETE` by design, and nothing here overrules it.

  ## The repair

  For each key range whose checksums disagree, the legacy rows in that range are read through
  Ash (the projection actor, the estate's tenant) and each is repaired as the drain would have
  ingested it (`AshEnterprise.Ledger.UserIngestion`): projected through
  `AshEnterprise.Legacy.UserProjection.project/2`, the one projection entry point the backfill
  and the drain share, and its KYC compliance events recorded from the projected row
  (`AshEnterprise.Compliance.Kyc.record_from_projection/2`), in one transaction. A repaired
  row's verdict therefore follows its repaired state, and a user the drain never saw is
  evaluated. A row whose events cannot be recorded (the estate has no active compliance
  bundle) is rolled back and counted as refused, so the estate does not read as converged.
  The comparison then runs again, and the report says whether the estate converged.

  ## The report

  A `[:ash_enterprise, :legacy, :reconcile]` telemetry event (measurements: counts; metadata:
  key ranges, `agrees?`, `converged?`) and one log line. Both carry counts and key ranges
  only: a legacy key is a number, and no login, email or name leaves this module.

  Run it on demand with `AshEnterprise.Legacy.ReconcileWorker.run/1`; `repair?: false` reports
  without writing.
  """

  use Oban.Worker, queue: :ash_strangler_ledger, max_attempts: 1, unique: [period: 300]

  require Ash.Query
  require Logger

  # Sobelow reads `@sobelow_skip` out of the source AST, so nothing in the compiled module ever
  # consults it; persisting it writes it into the beam, which counts as a use (same pattern as
  # AshEnterprise.Ledger.UserDrainWorker).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  alias AshEnterprise.Accounts.ProjectedUser
  alias AshEnterprise.Compliance.Kyc
  alias AshEnterprise.Legacy.Estate
  alias AshEnterprise.Legacy.User, as: LegacyUser
  alias AshEnterprise.Legacy.UserBackfill
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Repo
  alias AshStrangler.Reconciler

  @event [:ash_enterprise, :legacy, :reconcile]
  @orphan_key_cap 50

  # Compared with the projection's own normalization: `email` is a `:ci_string` and `full_name`
  # and `login` are trimmed strings, exactly as `AshStrangler.Reconciler.plan/1` derives them.
  @columns [login: "login", email: "email", full_name: "full_name", legacy_state: "legacy_state"]
  @normalize %{login: :trim, email: :ci_string, full_name: :trim}

  @type report :: %{
          view_agrees?: boolean(),
          projection_agrees?: boolean(),
          counts: map(),
          mismatched_ranges: [{integer(), integer()}],
          repaired: non_neg_integer(),
          refused: non_neg_integer(),
          converged?: boolean(),
          orphaned: %{count: non_neg_integer(), keys: [integer()]}
        }

  @impl Oban.Worker
  def perform(_job) do
    _report = run()
    :ok
  end

  @doc """
  Compares, repairs, compares again, reports. Returns the report map.

  `repair?: false` stops after the first comparison.
  """
  @spec run(keyword()) :: report()
  def run(opts \\ []) do
    repair? = Keyword.get(opts, :repair?, true)

    view = Reconciler.diff(LegacyUser)
    before = diff_projection()
    ranges = ranges(before)

    {repaired, refused, final} =
      if repair? and ranges != [] do
        {ok, bad} = repair(ranges)
        {ok, bad, diff_projection()}
      else
        {0, 0, before}
      end

    report = %{
      view_agrees?: view.agrees?,
      projection_agrees?: before.agrees?,
      counts: %{
        legacy: before.counts.legacy,
        projected: before.counts.view,
        view_vs_legacy_drift: view.counts.drift
      },
      mismatched_ranges: ranges,
      repaired: repaired,
      refused: refused,
      converged?: final.agrees?,
      orphaned: orphans()
    }

    emit(report)
    report
  end

  # --- the comparison ----------------------------------------------------------------------

  # `legacy:` is the compatibility view and `view:` is the projection, in the reconciler's
  # vocabulary for "the source of truth" and "the thing that should match it".
  defp diff_projection do
    Reconciler.diff(Repo,
      legacy: [relation: view_side(), key: "__legacy_id"],
      view: [relation: projected_side(), key: "legacy_id"],
      columns: @columns,
      normalize: @normalize
    )
  end

  # SQL justification (ash-discipline: raw SQL is for ops tooling the query layer cannot
  # express). `AshStrangler.Reconciler` takes each side of the comparison as a SQL `FROM` item and
  # runs one statement per batch, so the two sides must be spelled as relations. Both are
  # read-only subselects built from names the resources own (schema, table, tenant constant);
  # nothing user-supplied is interpolated, and the organization id is cast through
  # `Ecto.UUID.cast!/1` first. The repair itself goes through Ash.
  defp view_side do
    "(SELECT * FROM #{view_relation()} WHERE archived_at IS NULL) AS legacy_view"
  end

  defp projected_side do
    "(SELECT p.* FROM #{projected_relation()} p " <>
      "WHERE p.organization_id = '#{organization_id()}' " <>
      "AND EXISTS (SELECT 1 FROM #{view_relation()} v " <>
      "WHERE v.__legacy_id = p.legacy_id AND v.archived_at IS NULL)) AS projected"
  end

  defp view_relation do
    LegacyUser |> Reconciler.plan() |> Keyword.fetch!(:view) |> Keyword.fetch!(:relation)
  end

  defp projected_relation do
    schema = AshPostgres.DataLayer.Info.schema(ProjectedUser) || "public"
    table = AshPostgres.DataLayer.Info.table(ProjectedUser)
    ~s("#{schema}"."#{table}")
  end

  defp organization_id, do: Ecto.UUID.cast!(Estate.organization_id())

  defp ranges(%{checksums: %{mismatched: mismatched}}),
    do: Enum.map(mismatched, &{&1.lower, &1.upper})

  # Projected rows of the estate with no row at all in the legacy view. Reported, never deleted.
  # Every interpolated value is a relation name the resources own or a cast uuid (see above).
  @sobelow_skip ["SQL.Query"]
  defp orphans do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        "SELECT p.legacy_id FROM #{projected_relation()} p " <>
          "WHERE p.organization_id = '#{organization_id()}' " <>
          "AND NOT EXISTS (SELECT 1 FROM #{view_relation()} v WHERE v.__legacy_id = p.legacy_id) " <>
          "ORDER BY p.legacy_id",
        []
      )

    keys = List.flatten(rows)
    %{count: length(keys), keys: Enum.take(keys, @orphan_key_cap)}
  end

  # --- the repair --------------------------------------------------------------------------

  defp repair(ranges) do
    opts = [actor: SystemActor.projection(), tenant: Estate.organization_id(), authorize?: false]
    run_id = Ecto.UUID.generate()

    ranges
    |> Enum.flat_map(fn {lower, upper} -> read_range(lower, upper, opts) end)
    |> Enum.reduce({0, 0}, fn row, {ok, bad} ->
      case repair_row(row, "reconcile:#{run_id}:#{row.legacy_id}") do
        {:ok, _projected} -> {ok + 1, bad}
        {:error, _reason} -> {ok, bad + 1}
      end
    end)
  end

  # What the drain's ingestion does with a row, in one transaction: the projection, then the
  # compliance events the projected row supports, attributed to the same system actor.
  defp repair_row(row, correlation_id) do
    Repo.transaction(fn ->
      with {:ok, projected} <- UserBackfill.project(row, "reconcile"),
           :ok <-
             Kyc.record_from_projection(projected,
               actor: SystemActor.projection(),
               correlation_id: correlation_id
             ) do
        projected
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp read_range(lower, upper, opts) do
    LegacyUser
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.filter(legacy_id >= ^lower and legacy_id <= ^upper)
    |> Ash.read!(opts)
  end

  # --- the report --------------------------------------------------------------------------

  defp emit(report) do
    :telemetry.execute(
      @event,
      %{
        legacy: report.counts.legacy,
        projected: report.counts.projected,
        mismatched: length(report.mismatched_ranges),
        repaired: report.repaired,
        refused: report.refused,
        orphaned: report.orphaned.count
      },
      %{
        view_agrees?: report.view_agrees?,
        projection_agrees?: report.projection_agrees?,
        converged?: report.converged?,
        mismatched_ranges: report.mismatched_ranges,
        orphaned_keys: report.orphaned.keys
      }
    )

    Logger.info(
      "legacy reconcile: view_agrees=#{report.view_agrees?} " <>
        "projection_agrees=#{report.projection_agrees?} legacy=#{report.counts.legacy} " <>
        "projected=#{report.counts.projected} mismatched_ranges=#{inspect(report.mismatched_ranges)} " <>
        "repaired=#{report.repaired} refused=#{report.refused} " <>
        "orphaned=#{report.orphaned.count} converged=#{report.converged?}"
    )
  end
end
