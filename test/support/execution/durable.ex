defmodule AshEnterprise.Test.Execution.Durable do
  @moduledoc """
  Helpers the governed-invocation tests in the durability tier share: a clinic with a
  member who holds no role, the test target's committed effects, and the `:execute`
  jobs as Oban committed them.

  Nothing here rolls back. Every helper keys what it reads by the tenant or the
  invocation key a test created.
  """

  import Ecto.Query
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Invocation.ExecuteWorker
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Repo
  alias AshEnterprise.Test.DailyFixtures
  alias AshEnterprise.Test.Execution, as: Notes

  @record "AshEnterprise.Test.Execution.ClinicNote.record"
  @reviewed "AshEnterprise.Test.Execution.ClinicNote.record_reviewed"

  @doc "The internal target that needs no approval."
  def record_target, do: @record

  @doc "The internal target a person confirms first."
  def reviewed_target, do: @reviewed

  @doc "A fresh clinic and a member of it who holds no role at all."
  def clinic! do
    admin = DailyFixtures.tenant!()
    nurse = DailyFixtures.member!(admin, "Nurse #{System.unique_integer([:positive])}", [])
    %{admin: admin, nurse: nurse, tenant: nurse.tenant}
  end

  @doc "Options for the job runner in `tenant`: how the machinery reads and writes rows."
  def oban(tenant), do: [actor: SystemActor.oban(), tenant: tenant]

  @doc "`member` invokes `target` with `args` under `key`."
  def invoke(member, target, args, key, extra \\ %{}) do
    Execution.invoke(target, args, Map.put(extra, :key, key),
      actor: member.actor,
      tenant: member.tenant
    )
  end

  @doc "The invocation rows under `key` in `tenant`, as committed now."
  def rows(tenant, key) do
    Execution.list_invocations!(Keyword.put(oban(tenant), :query, filter: [invocation_key: key]))
  end

  @doc "How many clinic notes titled `title` are committed in `tenant`: committed effects."
  def effects(tenant, title) do
    [query: [filter: [title: title]], tenant: tenant, authorize?: false]
    |> Notes.list_notes!()
    |> length()
  end

  @doc """
  Rewrites `row` as it would be had it been requested under an earlier declaration of its
  target: its `target_digest` is no longer the current one, as after a deploy that
  changed the target. Written past the actions, because no action may rewrite what was
  requested.
  """
  def requested_under_earlier_definition!(row) do
    earlier = AshAgent.Digest.sha256_hex(%{"effects" => row.effects, "release" => "earlier"})

    {1, _} =
      Repo.update_all(
        from(i in "exec_invocations", where: i.id == type(^row.id, Ecto.UUID)),
        set: [target_digest: earlier]
      )

    :ok
  end

  @doc "`member` invokes `ReferralBoard.<action>` for a synthetic patient, under a fresh key."
  def refer(member, action, extra \\ %{}) do
    invoke(
      member,
      "AshEnterprise.Test.Execution.ReferralBoard.#{action}",
      %{"patient" => "SYNTHETIC patient #{System.unique_integer([:positive])}"},
      "refer:#{System.unique_integer([:positive])}",
      extra
    )
  end

  @doc """
  Time passes for `row`: its `field` (`lease_expires_at`, `next_attempt_at`,
  `deadline_at`, `approval_expires_at`) is moved a minute into the past. Written past the actions, as the
  clock is.
  """
  def elapse!(row, field)
      when field in [:lease_expires_at, :next_attempt_at, :deadline_at, :approval_expires_at] do
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    {1, _} =
      Repo.update_all(
        from(i in "exec_invocations", where: i.id == type(^row.id, Ecto.UUID)),
        set: [{field, past}]
      )

    :ok
  end

  @doc "The invocation `id` as committed now."
  def committed(id, tenant), do: Execution.get_invocation!(id, oban(tenant))

  @doc "The `:execute` jobs Oban holds for the invocation `id`, oldest first."
  def jobs(id), do: jobs(id, ExecuteWorker)

  @doc "The jobs of `worker` Oban holds for the invocation `id`, oldest first."
  def jobs(id, worker) do
    worker = inspect(worker)

    Repo.all(
      from(j in Oban.Job,
        where: j.worker == ^worker and fragment("?->'primary_key'->>'id' = ?", j.args, ^id),
        order_by: j.id
      )
    )
  end

  @doc "Ids named by `:execute` jobs whose invocation row does not exist: orphans."
  def orphan_job_ids do
    worker = inspect(ExecuteWorker)

    named =
      Repo.all(
        from(j in Oban.Job,
          where: j.worker == ^worker,
          select: fragment("?->'primary_key'->>'id'", j.args)
        )
      )

    existing =
      Execution.list_invocations!(
        actor: SystemActor.oban(),
        authorize?: false,
        query: [filter: [id: [in: named]]]
      )
      |> MapSet.new(& &1.id)

    Enum.reject(named, &MapSet.member?(existing, &1))
  end

  @doc """
  Stops the `:execution` queue for the rest of the test, so a test can drive claims and
  deliveries itself. On exit, jobs the test left behind are cancelled before the queue
  resumes, so they never run in a later test.
  """
  def pause_execution! do
    :ok = Oban.pause_queue(queue: :execution)

    on_exit(fn ->
      Oban.cancel_all_jobs(from(j in Oban.Job, where: j.queue == "execution"))
      Oban.resume_queue(queue: :execution)
    end)
  end
end
