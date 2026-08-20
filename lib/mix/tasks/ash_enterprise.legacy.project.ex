defmodule Mix.Tasks.AshEnterprise.Legacy.Project do
  @shortdoc "Project every legacy user row into this application's own table"

  @moduledoc """
  Backfills `projected_users` from the legacy estate.

  `AshEnterprise.Legacy.Projection` keeps the table current from that point on: it runs on every
  legacy write, through the notification `AshStrangler.Listener` already dispatches. This task
  is the one-off that establishes the starting state, and the repair for anything the projector
  missed while it was not running.

      mix ash_enterprise.legacy.project

  Idempotent, because the projection is an upsert keyed on `legacy_id`. Running it twice
  produces the same table and no duplicate rows, which is what makes it safe to put at the end
  of `mix ash_enterprise.legacy.setup` and safe to re-run by hand after an incident.

  ## Why a backfill exists at all, when the projector is live

  The projector reacts to *changes*. A row that has not changed since the projector started has
  never produced a notification, so it has never been projected — and the rows in a legacy
  database that has been running for fifteen years are overwhelmingly of that kind. A live
  projector with no backfill shows you an empty table that fills up one edit at a time, which
  looks like the feature is broken.

  `AshStrangler.Backfill` is the batched, resumable, keyset-paginated machinery for doing this
  at real scale, and it is deliberately **not** what this uses: it backfills columns *within* a
  legacy table, which is step 4 of the plan. This copies rows *out* of one, and the legacy
  estate here is nine users, so a plain read-and-project is the honest implementation. At a
  million rows it would need to stream and to commit per batch, and the moduledoc should not
  pretend otherwise.
  """

  use Mix.Task

  alias AshEnterprise.Legacy
  alias AshEnterprise.Legacy.Estate
  alias AshEnterprise.Legacy.Projection
  alias AshEnterprise.Platform.SystemActor

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_argv) do
    ensure_table!()

    opts = [actor: SystemActor.projection(), tenant: Estate.organization_id(), authorize?: false]

    rows =
      Legacy.User
      |> Ash.Query.for_read(:read, %{}, opts)
      |> Ash.read!(opts)

    # Through `Projection.project_row/1`, not a second spelling of it. Rebuilding the attribute
    # map here is what made the backfill and the live projector disagree about `lifecycle_status`
    # -- the upsert was duplicated and the state-machine transition was not.
    {projected, refused} =
      Enum.reduce(rows, {0, []}, fn row, {ok, bad} ->
        case Projection.project_row(row) do
          :ok -> {ok + 1, bad}
          {:error, reason} -> {ok, [{row.legacy_id, inspect(reason)} | bad]}
        end
      end)

    Mix.shell().info([
      :green,
      "projected #{projected} of #{length(rows)} legacy users",
      :reset
    ])

    # Reported rather than raised. A row the new model refuses is a data-quality finding about
    # the legacy estate, which is the sort of thing this demo exists to surface -- and failing
    # the whole task would make one bad row hide the other eight good ones.
    for {legacy_id, message} <- Enum.reverse(refused) do
      Mix.shell().info([:yellow, "  refused legacy_id #{legacy_id}: ", :reset, message])
    end
  end

  # Ordering, checked once and reported as itself.
  #
  # `projected_users` is Ash-owned, so this task has to run after the migrations that create it
  # -- while `ash_enterprise.legacy.setup` has to run *before* them, because the strangler view
  # needs `legacy.users` to exist. Those two constraints point in opposite directions, which is
  # exactly why this was first wired into `legacy.setup` and produced nine
  # `relation "projected_users" does not exist` errors on a fresh database, each reported as a
  # refused row. One row refused is a data-quality finding worth printing; nine refused for the
  # same structural reason is a mistake wearing a finding's clothes.
  defp ensure_table! do
    %{rows: [[exists?]]} =
      AshEnterprise.Repo.query!("SELECT to_regclass('public.projected_users') IS NOT NULL")

    unless exists? do
      Mix.raise("""
      `projected_users` does not exist, so there is nothing to project into.

      Run the migrations first:

          mix ash.migrate

      This task is sequenced after `ash.setup` in the `setup` and `ecto.setup` aliases for the
      same reason. `mix ash_enterprise.legacy.setup` is sequenced *before* them, because the
      strangler view it creates needs `legacy.users` to exist -- the two orderings are opposite
      and both are load-bearing.
      """)
    end
  end
end
