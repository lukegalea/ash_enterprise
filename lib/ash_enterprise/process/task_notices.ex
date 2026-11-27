defmodule AshEnterprise.Process.TaskNotices do
  @moduledoc """
  This application's `AshBpmn.TaskNotifier` (`ash_bpmn` DESIGN.md §11.7): how the people a
  task's timer names are told. `config :ash_bpmn, task_notifier: #{inspect(__MODULE__)}`.

  The engine decides who (`AshBpmn.Notice.recipients`: the assignee of a claimed task,
  otherwise its candidates, plus the people an escalation just added, minus the task's
  exclusions). This module decides how:

    1. A team is expanded to its members in the task's organization, and the task's
       exclusions are subtracted again: excluding a person from a task excludes them from
       everything that names them through a team.
    2. Each person must be an active member of the task's organization
       (`AshEnterprise.Process.TenantPeople`).
    3. Each is given a `AshEnterprise.Process.TaskNotice` row (the in-app notice), then a
       message at their account's address (`AshEnterprise.Process.Senders.SendTaskNotice`),
       and the row is marked mailed.

  ## Idempotent by the notice's key

  The engine calls `deliver/2` after the timer's writes commit, at least once, and again
  with the same key whenever a call fails. A row is unique on `(key, user_id)` and a mailed
  row is not mailed again, so a retry writes no second row and sends each person one
  message.

  ## Everyone is told, and the answer says who was not

  Every person is told before the answer is given: one address that always fails silences
  nobody after it. Then:

    * everyone told: `:ok`;
    * someone's message failed: `{:error, {:not_mailed, count}}`, so the engine retries and
      only they are mailed again; on the engine's last attempt (`ctx.final_attempt?`) the
      answer is `{:ok, %{not_reached: [...]}}` instead, naming the recipients not reached;
    * a recipient that resolves to no active member of the organization (another
      organization's person, a deactivated one, an empty or archived team) is named in
      `not_reached` with `:not_an_active_member` on any attempt, because a retry cannot
      change it.

  A recipient team is not reached when any of its members was not mailed
  (`{:members_not_mailed, count}`): the record must not say a whole team was told.

  ## Nobody to tell is a failure

  A notice that leaves nobody to tell (no recipients, or none who is an active member of
  the organization once teams and exclusions are applied) is
  `{:error, {:final, :nobody_to_tell}}`, never `:ok`: `:notice_delivered` must mean a person
  was told, and asking again finds the same nobody.
  """

  @behaviour AshBpmn.TaskNotifier

  require Logger

  alias AshBpmn.Notice
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Process.Senders.SendTaskNotice
  alias AshEnterprise.Process.{TaskNotice, TenantPeople}

  @impl true
  def deliver(%Notice{} = notice, ctx) do
    case notice.tenant || ctx[:tenant] do
      nil -> {:error, :no_tenant}
      tenant -> notice |> people(tenant) |> tell(notice, tenant, ctx)
    end
  end

  # Each recipient with the active members of the tenant it resolves to: a user recipient is
  # that user, a team recipient its members, minus the task's exclusions either way.
  defp people(notice, tenant) do
    excluded = MapSet.new(Map.get(notice.task, :excluded_principal_ids) || [])

    # A recipient the task excludes entirely (the requester, say) is not told on purpose, so
    # it is not named as not reached either.
    for recipient <- notice.recipients,
        ids =
          (case recipient do
             %{type: :team, id: id} -> TenantPeople.team_member_ids([id], tenant)
             %{id: id} -> [id]
           end),
        ids == [] or not Enum.all?(ids, &MapSet.member?(excluded, &1)) do
      users =
        ids
        |> Enum.reject(&MapSet.member?(excluded, &1))
        |> TenantPeople.active_users(tenant)

      {recipient, users}
    end
  end

  defp tell(resolved, notice, tenant, ctx) do
    users = resolved |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq_by(& &1.id)

    if users == [] do
      {:error, {:final, :nobody_to_tell}}
    else
      failed =
        for user <- users,
            match?({:error, _}, tell_one(user, notice, tenant)),
            into: MapSet.new(),
            do: user.id

      answer(resolved, failed, ctx)
    end
  end

  defp answer(resolved, failed, ctx) do
    inactive = for {recipient, []} <- resolved, do: {recipient, :not_an_active_member}

    cond do
      MapSet.size(failed) > 0 and not Map.get(ctx, :final_attempt?, false) ->
        {:error, {:not_mailed, MapSet.size(failed)}}

      MapSet.size(failed) == 0 and inactive == [] ->
        :ok

      true ->
        {:ok, %{not_reached: inactive ++ unmailed(resolved, failed)}}
    end
  end

  defp unmailed(resolved, failed) do
    for {recipient, users} <- resolved,
        missed = Enum.count(users, &MapSet.member?(failed, &1.id)),
        missed > 0 do
      case recipient do
        %{type: :team} -> {recipient, {:members_not_mailed, missed}}
        _user -> {recipient, :not_mailed}
      end
    end
  end

  defp tell_one(user, notice, tenant) do
    opts = [actor: SystemActor.oban(), tenant: tenant]

    with {:ok, row} <- record(user, notice, opts) do
      mail(row, user, notice, opts)
    end
  end

  defp record(user, notice, opts) do
    TaskNotice
    |> Ash.Changeset.for_create(
      :record,
      %{
        key: notice.key,
        user_id: user.id,
        owning_business_unit_id: user.owning_business_unit_id,
        task_id: notice.task.id,
        kind: notice.kind,
        due_at: notice.due_at,
        late: notice.late
      },
      opts
    )
    |> Ash.create()
  end

  defp mail(%{mailed_at: %DateTime{}}, _user, _notice, _opts), do: :ok

  defp mail(row, user, notice, opts) do
    case SendTaskNotice.deliver(notice.kind, to_string(user.email), as: standing(notice, user)) do
      {:ok, _sent} ->
        row
        |> Ash.Changeset.for_update(:mark_mailed, %{}, opts)
        |> Ash.update()
        |> case do
          {:ok, _row} -> :ok
          {:error, _error} = error -> error
        end

      {:error, _error} ->
        # The mailer's error is not logged or returned: it can carry the address.
        Logger.warning("task notice #{row.id} not mailed")
        {:error, :not_mailed}
    end
  end

  # Where the person stands on an escalated task (`ash_bpmn` DESIGN.md §11.6): its holder, who
  # keeps it; someone added while somebody else holds it, who can act only if the holder
  # delegates it to them; or someone who can act on an open task now.
  defp standing(%Notice{kind: :escalated, holder: %{type: :user, id: id}}, %{id: id}),
    do: :holder

  defp standing(%Notice{kind: :escalated, holder: %{}}, _user), do: :added_while_held
  defp standing(_notice, _user), do: :can_act
end
