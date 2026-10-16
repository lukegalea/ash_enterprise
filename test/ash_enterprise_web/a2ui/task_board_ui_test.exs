defmodule AshEnterpriseWeb.A2ui.TaskBoardUITest do
  @moduledoc """
  My tasks (`TaskBoardUI`, `/app/tasks`) driven through ash_a2ui's handler
  as the people who click it: the board's lanes, claim, complete and
  delegate as the clicking person, and the refusals — a person who is not a
  candidate cannot claim, and only the holder of a claimed task completes or
  delegates it.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3, brief!: 1]

  require Ash.Query

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Bpmn.{HumanTask, ProcessEvent}
  alias AshEnterpriseWeb.A2ui.TaskBoardUI

  setup do
    admin = tenant!()
    brief = brief!(admin)

    {:ok, task} =
      AshEnterprise.Agents.BriefDecision.open_task(brief,
        actor: admin.actor,
        tenant: admin.tenant
      )

    %{admin: admin, task: task}
  end

  defp reload(task, tenant), do: Ash.get!(HumanTask, task.id, tenant: tenant, authorize?: false)

  # A person who may read and work tasks but is not this task's candidate.
  defp colleague!(admin) do
    member!(admin, "Colleague", [
      {HumanTask, :read, :global},
      {HumanTask, :write, :global},
      {User, :read, :global}
    ])
  end

  defp lanes(person) do
    %{"updateDataModel" => %{"value" => value}} =
      AshA2ui.Info.build_data_model(TaskBoardUI, actor: person.actor, tenant: person.tenant)

    value["records"]
    |> Enum.filter(fn {_lane, rows} -> is_list(rows) end)
    |> Map.new(fn {lane, rows} -> {lane, Enum.map(rows, & &1["id"])} end)
  end

  defp lane(person, status) do
    lanes(person)
    |> Enum.find_value([], fn {lane, ids} -> if String.ends_with?(lane, status), do: ids end)
  end

  defp invoke(person, action, task, values \\ nil) do
    context =
      %{"action" => action, "recordId" => task.id, "component" => "board_#{task_lane(task)}"}

    context = if values, do: Map.put(context, "values", values), else: context

    AshA2ui.ActionHandler.handle(TaskBoardUI, %{"name" => "invoke", "context" => context},
      actor: person.actor,
      tenant: person.tenant
    )
  end

  defp task_lane(task),
    do: Ash.get!(HumanTask, task.id, authorize?: false, tenant: task.organization_id).status

  defp run(person, action, args) do
    HumanTask
    |> Ash.ActionInput.for_action(action, args, actor: person.actor, tenant: person.tenant)
    |> Ash.run_action()
  end

  test "the board shows the candidate's task in Open, and nobody else's", %{
    admin: admin,
    task: task
  } do
    assert task.id in lane(admin, "open")
    assert lane(admin, "claimed") == []

    # Holding every task grant is not candidacy: the task is not theirs.
    colleague = colleague!(admin)
    refute task.id in lane(colleague, "open")
  end

  test "Claim task claims it for the clicking candidate and records the claim", %{
    admin: admin,
    task: task
  } do
    assert {:ok, _messages} = invoke(admin, "claim_task", task)

    claimed = reload(task, admin.tenant)
    assert claimed.status == :claimed
    assert claimed.assignee_id == admin.user.id

    assert ProcessEvent
           |> Ash.Query.filter(task_id == ^task.id and kind == :task_claimed)
           |> Ash.exists?(tenant: admin.tenant, authorize?: false)

    assert task.id in lane(admin, "claimed")
  end

  test "a person who is not a candidate cannot claim the task", %{admin: admin, task: task} do
    colleague = colleague!(admin)

    # Not on their board, so the surface refuses it outright…
    assert {:error, _messages} = invoke(colleague, "claim_task", task)

    # …and the action itself refuses it, whatever their grants.
    assert {:error, %Ash.Error.Forbidden{}} =
             run(colleague, :claim_task, %{record_id: task.id})

    assert reload(task, admin.tenant).status == :open
  end

  test "Complete task decides a task the person holds", %{admin: admin, task: task} do
    assert {:ok, _} = invoke(admin, "claim_task", task)

    assert {:ok, _messages} =
             invoke(admin, "complete_task", task, %{
               "outcome" => "approved",
               "comment" => "Looks right"
             })

    done = reload(task, admin.tenant)
    assert done.status == :completed
    assert done.outcome == "approved"
    assert done.decided_by_id == admin.user.id
    assert lanes(admin) |> Map.values() |> List.flatten() == []
  end

  test "an open task cannot be completed or delegated before it is claimed", %{
    admin: admin,
    task: task
  } do
    assert {:error, _} = invoke(admin, "complete_task", task, %{"outcome" => "approved"})
    assert {:error, _} = run(admin, :complete_task, %{record_id: task.id, outcome: "approved"})
    assert {:error, _} = run(admin, :delegate_task, %{record_id: task.id, delegate_to: "x@y.z"})
    assert reload(task, admin.tenant).status == :open
  end

  test "Delegate task hands a held task on; the delegatee completes it", %{
    admin: admin,
    task: task
  } do
    colleague = colleague!(admin)
    assert {:ok, _} = invoke(admin, "claim_task", task)

    assert {:ok, _messages} =
             invoke(admin, "delegate_task", task, %{"delegate_to" => colleague.email})

    delegated = reload(task, admin.tenant)
    assert delegated.status == :claimed
    assert delegated.assignee_id == colleague.user.id
    assert delegated.delegated_from_id == admin.user.id

    # The task is now the colleague's: on their board, and theirs to decide.
    assert task.id in lane(colleague, "claimed")

    assert {:error, %Ash.Error.Forbidden{}} =
             run(admin, :complete_task, %{record_id: task.id, outcome: "approved"})

    assert {:ok, _messages} = invoke(colleague, "complete_task", task, %{"outcome" => "approved"})
    assert reload(task, admin.tenant).status == :completed
  end

  test "a task is not delegated to someone who could not see it", %{admin: admin, task: task} do
    outsider = member!(admin, "No task grants", [])
    assert {:ok, _} = invoke(admin, "claim_task", task)

    assert {:error, _} =
             run(admin, :delegate_task, %{record_id: task.id, delegate_to: outsider.email})

    assert reload(task, admin.tenant).assignee_id == admin.user.id
  end

  test "only the holder of a claimed task completes it", %{admin: admin, task: task} do
    colleague = colleague!(admin)
    assert {:ok, _} = invoke(admin, "claim_task", task)

    assert {:error, %Ash.Error.Forbidden{}} =
             run(colleague, :complete_task, %{record_id: task.id, outcome: "approved"})

    assert reload(task, admin.tenant).status == :claimed
  end
end
