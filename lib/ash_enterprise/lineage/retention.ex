defmodule AshEnterprise.Lineage.Retention do
  @moduledoc """
  How long lineage is kept: **14 days** by default, then deleted.

      config :ash_enterprise, AshEnterprise.Lineage.Retention, days: 14

  Lineage here is an operational view ("what ran, what broke, what fed
  what"), not a record anyone is promised: the audit log is the permanent
  record of consequence, and stays untouched. Fourteen days covers the two
  questions this app answers — is something failing now, and what did last
  week's runs touch — and matches the Lineage app's widest window.

  The volume it bounds: a dogfood instance syncs Gmail, Slack and Calendar
  per linked account every 5–15 minutes, and each sync step is one run of
  about five job runs (the sync, its landings, its projection and the
  canonical tables it wrote), however many rows it wrote — the store
  coalesces per run (`AshEnterprise.Lineage.Recorder`). Three accounts are
  then a few thousand job runs a day, and some tens of thousands in the
  window: small tables, deleted daily by `AshEnterprise.Lineage.PruneWorker`.

  `prune/1` deletes runs whose last event is older than the cutoff (their
  job runs go with them, by foreign key), then jobs not seen since the
  cutoff. Deletion is a hard delete: these resources are not soft-deletable.
  """

  require Ash.Query

  alias AshEnterprise.Lineage.{Job, Run}
  alias AshEnterprise.Platform.SystemActor

  @default_days 14

  @doc "The retention window in days."
  @spec days() :: pos_integer()
  def days do
    :ash_enterprise
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:days, @default_days)
  end

  @doc """
  Deletes lineage older than the window, across every tenant. Options:
  `:now`, `:days`. Returns the counts deleted.
  """
  @spec prune(keyword()) :: %{runs: non_neg_integer(), jobs: non_neg_integer()}
  def prune(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    cutoff = DateTime.add(now, -Keyword.get(opts, :days, days()) * 86_400, :second)

    runs = Run |> Ash.Query.filter(last_event_at < ^cutoff) |> destroy_all()
    jobs = Job |> Ash.Query.filter(last_run_at < ^cutoff) |> destroy_all()

    %{runs: runs, jobs: jobs}
  end

  # Counted first: an atomic bulk delete reports no records.
  defp destroy_all(query) do
    count = Ash.count!(query, actor: SystemActor.lineage())

    if count > 0 do
      Ash.bulk_destroy!(query, :prune, %{},
        actor: SystemActor.lineage(),
        strategy: [:atomic, :stream],
        return_records?: false,
        return_errors?: true
      )
    end

    count
  end
end
