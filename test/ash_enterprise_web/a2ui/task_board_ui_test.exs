defmodule AshEnterpriseWeb.A2ui.TaskBoardUITest do
  @moduledoc """
  My tasks (`TaskBoardUI`, `/app/tasks`) driven through ash_a2ui's handler
  as the people who click it: the board's lanes, claim, complete and
  delegate as the clicking person, and the refusals — a person who is not a
  candidate cannot claim, a task is delegated only to another of its
  candidates, and only the holder of a claimed task completes, delegates or
  (from Approvals) decides it.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3, brief!: 1]

  require Ash.Query

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Bpmn.{HumanTask, ProcessEvent, TaskCandidate}
  alias AshEnterpriseWeb.A2ui.{ApprovalsUI, TaskBoardUI}

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

  # Makes `person` one of the task's candidates, as assignment resolution
  # would have when the task was created.
  defp candidate!(task, person) do
    TaskCandidate.create!(
      %{task_id: task.id, principal_type: :user, principal_id: person.user.id},
      tenant: person.tenant,
      authorize?: false
    )

    person
  end

  defp approvals_invoke(person, action, task) do
    AshA2ui.ActionHandler.handle(
      ApprovalsUI,
      %{
        "name" => "invoke",
        "context" => %{"action" => action, "recordId" => task.id, "component" => "table"}
      },
      actor: person.actor,
      tenant: person.tenant
    )
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
    colleague = admin |> colleague!() |> then(&candidate!(task, &1))
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

  # Maker-checker is subtraction at candidate resolution: the excluded
  # requester has no candidate row, exactly like this colleague. Holding every
  # task grant does not make them someone the task may be handed to.
  test "a task is not delegated to someone who is not its candidate", %{
    admin: admin,
    task: task
  } do
    colleague = colleague!(admin)
    assert {:ok, _} = invoke(admin, "claim_task", task)

    assert {:error, %Ash.Error.Invalid{} = error} =
             run(admin, :delegate_task, %{record_id: task.id, delegate_to: colleague.email})

    assert Exception.message(error) =~ "not one of this task's approvers"
    assert reload(task, admin.tenant).assignee_id == admin.user.id

    # …so they can never decide it, by either door.
    assert {:error, %Ash.Error.Forbidden{}} =
             run(colleague, :complete_task, %{record_id: task.id, outcome: "approved"})

    assert {:error, %Ash.Error.Forbidden{}} = run(colleague, :approve, %{record_id: task.id})
    assert reload(task, admin.tenant).status == :claimed
  end

  test "whoever delegated a task cannot then decide it from Approvals", %{
    admin: admin,
    task: task
  } do
    colleague = admin |> colleague!() |> then(&candidate!(task, &1))
    assert {:ok, _} = invoke(admin, "claim_task", task)
    assert {:ok, _} = invoke(admin, "delegate_task", task, %{"delegate_to" => colleague.email})

    # Still a candidate, no longer the holder: refused by the action…
    for action <- [:approve, :reject] do
      assert {:error, %Ash.Error.Forbidden{}} = run(admin, action, %{record_id: task.id})
    end

    # …and through the Approvals surface, as a refusal.
    for action <- ["approve", "reject"] do
      assert {:error, messages} = approvals_invoke(admin, action, task)
      assert AshEnterprise.Acp.ExtMethods.failure_kind(messages) == :forbidden
    end

    assert reload(task, admin.tenant).status == :claimed

    # The holder decides it there.
    assert {:ok, _messages} = approvals_invoke(colleague, "approve", task)
    done = reload(task, admin.tenant)
    assert done.status == :completed
    assert done.decided_by_id == colleague.user.id
  end

  test "an open task is any candidate's to decide from Approvals", %{admin: admin, task: task} do
    assert {:ok, _messages} = approvals_invoke(admin, "approve", task)
    assert reload(task, admin.tenant).status == :completed
  end

  # Candidacy grants read (ADR 0009, note of 2026-10-17): a candidate holding
  # no task grant at all is someone a task may be handed to, and reads and
  # completes it through their candidacy.
  test "a candidate with no task grant takes a delegated task and completes it", %{
    admin: admin,
    task: task
  } do
    stranger = member!(admin, "No task grants", [])
    candidate!(task, stranger)
    assert {:ok, _} = invoke(admin, "claim_task", task)

    assert {:ok, _} =
             run(admin, :delegate_task, %{record_id: task.id, delegate_to: stranger.email})

    assert reload(task, admin.tenant).assignee_id == stranger.user.id

    # A fresh request: their context now holds the task.
    stranger = %{stranger | actor: AshEnterprise.Test.DailyFixtures.actor(stranger.user)}
    assert task.id in lane(stranger, "claimed")

    assert {:ok, _} = invoke(stranger, "complete_task", task, %{"outcome" => "approved"})
    done = reload(task, admin.tenant)
    assert done.status == :completed
    assert done.decided_by_id == stranger.user.id
  end

  test "a person with no task grant and no candidacy reads no task and acts on none", %{
    admin: admin,
    task: task
  } do
    outsider = member!(admin, "No task grants", [])
    assert {:ok, _} = invoke(admin, "claim_task", task)

    # Not a candidate, so not someone it may be handed to…
    assert {:error, %Ash.Error.Invalid{} = error} =
             run(admin, :delegate_task, %{record_id: task.id, delegate_to: outsider.email})

    assert Exception.message(error) =~ "not one of this task's approvers"
    assert reload(task, admin.tenant).assignee_id == admin.user.id

    # …and with no live task they read nothing and run no act.
    assert [] == Ash.read!(HumanTask, actor: outsider.actor, tenant: outsider.tenant)

    for {action, args} <- [
          claim_task: %{record_id: task.id},
          approve: %{record_id: task.id},
          complete_task: %{record_id: task.id, outcome: "approved"}
        ] do
      assert {:error, %Ash.Error.Forbidden{}} = run(outsider, action, args)
    end
  end

  test "Complete refuses an outcome the task's step does not declare", %{
    admin: admin,
    task: task
  } do
    assert {:ok, _} = invoke(admin, "claim_task", task)

    # The morning brief's step declares approved / rejected; `confirm` is
    # another step's outcome, offered by the picker but not by this step.
    assert {:error, %Ash.Error.Invalid{} = error} =
             run(admin, :complete_task, %{record_id: task.id, outcome: "confirm"})

    assert Exception.message(error) =~ "approved or rejected"

    # Not on the picker at all: refused before the task is read.
    assert {:error, %Ash.Error.Invalid{}} =
             run(admin, :complete_task, %{record_id: task.id, outcome: "approvd"})

    assert reload(task, admin.tenant).status == :claimed
  end

  test "the task's detail lists the outcomes its step declares", %{admin: admin, task: task} do
    assert ["approved", "rejected"] ==
             HumanTask
             |> Ash.get!(task.id,
               actor: admin.actor,
               tenant: admin.tenant,
               load: [:declared_outcomes]
             )
             |> Map.fetch!(:declared_outcomes)
  end

  test "only the holder of a claimed task completes it", %{admin: admin, task: task} do
    colleague = colleague!(admin)
    assert {:ok, _} = invoke(admin, "claim_task", task)

    assert {:error, %Ash.Error.Forbidden{}} =
             run(colleague, :complete_task, %{record_id: task.id, outcome: "approved"})

    assert reload(task, admin.tenant).status == :claimed
  end
end
