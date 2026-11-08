defmodule AshEnterprise.Showcase.History.HeldJobs do
  @moduledoc """
  The Oban engine the showcase history seed runs on (`mix ash_enterprise.demo --history`,
  `AshEnterprise.Showcase.History`): Oban's Basic engine, with one difference while a
  process holds its jobs (`hold/2`).

  The seed arms fault points, which live in its node's application env, and runs a beat
  whose work is Oban jobs. Those jobs go into the table every node on the database polls,
  and a server running beside the seed would claim them and run them unarmed. So while the
  seed holds:

    * a job it inserts *due now* is written `scheduled` half an hour ahead, with
      `meta.held_by` naming the hold. No producer fetches a scheduled job, and no stager
      promotes it until then. It is still written in the inserting transaction, so a
      rollback still removes it. A job inserted for later (a timer) is written as asked:
      it fires on whichever node runs when it is due, as any timer does;
    * `Oban.drain_queue/1`, called by the holder, fetches only the jobs it holds (ignoring
      the half hour), marks them `executing` and clears the mark. Their retries and snoozes
      are then ordinary jobs, for any node.

  If the seed dies holding jobs, they are ordinary scheduled jobs that a server runs, unarmed,
  when the half hour is up: the recovery a real crash gets. Anything else, and every other
  process, is the Basic engine unchanged, so configuring this engine changes nothing until
  something holds.

  A hold belongs to the process that took it and to the processes it starts (`$callers`),
  the way Oban's own inline testing mode is scoped, so a test holding jobs does not hold
  another test's.

  `oban_config/1` is the rest of the seed's isolation. Every queue stays configured (AshOban
  refuses to start without the queues its triggers name) but starts paused and *held only*:
  its producer fetches nothing for a process outside a hold, even if a resume is broadcast to
  every node. An empty crontab, no other plugin, no stager, and a peer that never leads, so
  the seed's node never fetches a job it did not insert, never runs a sweep, and never takes
  leadership from the server.
  """

  @behaviour Oban.Engine

  import Ecto.Query

  alias Ecto.Changeset
  alias Oban.Engines.Basic
  alias Oban.{Job, Repo}

  @hold_seconds 30 * 60
  @key :ash_enterprise_held_jobs

  @doc """
  The seed's Oban configuration: `config` with this engine, and with nothing that fetches or
  sweeps on its own.
  """
  @spec oban_config(keyword()) :: keyword()
  def oban_config(config) do
    queues =
      for {name, _limit_or_opts} <- config[:queues] || [],
          do: {name, [limit: 1, paused: true, held_only: true]}

    Keyword.merge(config,
      engine: __MODULE__,
      queues: queues,
      # AshOban refuses to start without a cron plugin to add its schedulers to; cron
      # enqueues only on the leader, which this node never is.
      plugins: [{Oban.Plugins.Cron, crontab: []}],
      stager: false,
      peer: {Oban.Peers.Isolated, [leader?: false]}
    )
  end

  @doc """
  Runs `fun` holding the jobs this process (and the processes it starts) inserts, under a
  new hold. Returns `fun`'s result. The hold ends with `fun`, held jobs or not: what is
  still held is drained by `drain!/0` inside `fun`, or left to the half hour.
  """
  @spec hold((-> result)) :: result when result: term()
  def hold(fun) when is_function(fun, 0) do
    previous = Process.get(@key)
    Process.put(@key, Ecto.UUID.generate())

    try do
      fun.()
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  @doc "The hold the calling process is under, or `nil`."
  @spec holder() :: String.t() | nil
  def holder do
    Enum.find_value([self() | Process.get(:"$callers", [])], fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} -> Keyword.get(dictionary, @key)
        nil -> nil
      end
    end)
  end

  @doc """
  Performs, in this process, every job this process's hold still holds, queue by queue, until
  none is left (`Oban.drain_queue/1`, recursing). Returns how many ran.
  """
  @spec drain!(non_neg_integer()) :: non_neg_integer()
  def drain!(rounds \\ 50)
  def drain!(0), do: raise("held jobs did not drain")

  def drain!(rounds) do
    case held_queues() do
      [] ->
        0

      queues ->
        ran =
          for queue <- queues, reduce: 0 do
            count ->
              counts = Oban.drain_queue(queue: queue, with_recursion: true)
              count + Enum.sum(Map.values(counts))
          end

        ran + drain!(rounds - 1)
    end
  end

  @doc "The queues that hold jobs of this process's hold."
  @spec held_queues() :: [String.t()]
  def held_queues do
    case holder() do
      nil ->
        []

      holder ->
        Repo.all(
          Oban.config(),
          held(holder) |> distinct(true) |> select([j], j.queue)
        )
    end
  end

  defp held(holder) do
    Job
    |> where([j], j.state == "scheduled")
    |> where([j], fragment("?->>'held_by' = ?", j.meta, ^holder))
  end

  # --- the engine -------------------------------------------------------------------

  # `held_only: true` (the seed's queues, `oban_config/1`): the producer fetches only for a
  # process under a hold, which a producer never is.
  @impl Oban.Engine
  def init(conf, opts) do
    {held_only?, opts} = Keyword.pop(opts, :held_only, false)
    with {:ok, meta} <- Basic.init(conf, opts), do: {:ok, Map.put(meta, :held_only, held_only?)}
  end

  @impl Oban.Engine
  def put_meta(conf, meta, key, value), do: Basic.put_meta(conf, meta, key, value)

  @impl Oban.Engine
  def check_meta(conf, meta, running), do: Basic.check_meta(conf, meta, running)

  @impl Oban.Engine
  def refresh(conf, meta), do: Basic.refresh(conf, meta)

  @impl Oban.Engine
  def shutdown(conf, meta), do: Basic.shutdown(conf, meta)

  @impl Oban.Engine
  def insert_job(conf, changeset, opts),
    do: Basic.insert_job(conf, held_change(changeset, holder()), opts)

  @impl Oban.Engine
  def insert_all_jobs(conf, changesets, opts) do
    holder = holder()
    Basic.insert_all_jobs(conf, Enum.map(changesets, &held_change(&1, holder)), opts)
  end

  @impl Oban.Engine
  def fetch_jobs(conf, meta, running) do
    case {holder(), meta} do
      {nil, %{held_only: true}} -> {:ok, {meta, []}}
      {nil, _meta} -> Basic.fetch_jobs(conf, meta, running)
      {holder, _meta} -> fetch_held(conf, meta, holder)
    end
  end

  @impl Oban.Engine
  def stage_jobs(conf, queryable, opts), do: Basic.stage_jobs(conf, queryable, opts)

  @impl Oban.Engine
  def prune_jobs(conf, queryable, opts), do: Basic.prune_jobs(conf, queryable, opts)

  @impl Oban.Engine
  def rescue_jobs(conf, queryable, opts), do: Basic.rescue_jobs(conf, queryable, opts)

  @impl Oban.Engine
  def check_available(conf), do: Basic.check_available(conf)

  @impl Oban.Engine
  def complete_job(conf, job), do: Basic.complete_job(conf, job)

  @impl Oban.Engine
  def discard_job(conf, job), do: Basic.discard_job(conf, job)

  @impl Oban.Engine
  def error_job(conf, job, seconds), do: Basic.error_job(conf, job, seconds)

  @impl Oban.Engine
  def snooze_job(conf, job, seconds), do: Basic.snooze_job(conf, job, seconds)

  @impl Oban.Engine
  def cancel_job(conf, job), do: Basic.cancel_job(conf, job)

  @impl Oban.Engine
  def cancel_all_jobs(conf, queryable), do: Basic.cancel_all_jobs(conf, queryable)

  @impl Oban.Engine
  def delete_job(conf, job), do: Basic.delete_job(conf, job)

  @impl Oban.Engine
  def delete_all_jobs(conf, queryable), do: Basic.delete_all_jobs(conf, queryable)

  @impl Oban.Engine
  def retry_job(conf, job), do: Basic.retry_job(conf, job)

  @impl Oban.Engine
  def retry_all_jobs(conf, queryable), do: Basic.retry_all_jobs(conf, queryable)

  @impl Oban.Engine
  def update_job(conf, job, changes), do: Basic.update_job(conf, job, changes)

  # A job due now becomes a held one; a job for later, or outside a hold, is unchanged.
  defp held_change(changeset, nil), do: changeset

  defp held_change(changeset, holder) do
    if Changeset.get_field(changeset, :state) == "available" do
      meta = Changeset.get_field(changeset, :meta) || %{}

      changeset
      |> Changeset.put_change(:state, "scheduled")
      |> Changeset.put_change(:scheduled_at, DateTime.add(DateTime.utc_now(), @hold_seconds))
      |> Changeset.put_change(:meta, Map.put(meta, "held_by", holder))
    else
      changeset
    end
  end

  # Basic's fetch, over this hold's jobs in the queue instead of the queue's available ones.
  defp fetch_held(conf, meta, holder) do
    ids =
      held(holder)
      |> where([j], j.queue == ^meta.queue)
      |> where([j], j.attempt < j.max_attempts)
      |> order_by([j], asc: j.priority, asc: j.id)
      |> limit(^meta.limit)
      |> select([j], j.id)
      |> lock("FOR UPDATE SKIP LOCKED")

    query =
      Job
      |> where([j], j.id in subquery(ids))
      |> select([j], j)
      |> update([j],
        set: [
          state: "executing",
          attempted_at: ^DateTime.utc_now(),
          attempted_by: ^[meta.node, meta.uuid],
          meta: fragment("? - 'held_by'", j.meta)
        ],
        inc: [attempt: 1]
      )

    Repo.transaction(conf, fn ->
      {_count, jobs} = Repo.update_all(conf, query, [])
      {meta, jobs}
    end)
  end
end
