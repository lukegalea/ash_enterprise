defmodule AshEnterprise.Execution.HumanWaitTest do
  @moduledoc """
  A run that waits days on a person (ADR 0056, "Waiting on a person"): for the answer to
  a question it asked (`AshEnterprise.Execution.HumanInput`), and for a four-eyes
  sign-off of a tool call. While it waits, it is rows: no Oban job exists for the run or
  its tool call, and the sweeps that run every minute find nothing to do. The person
  acts, the sweeps run again, and the run carries on to its answer.

  There is no clock to move: the triggers compare against the database's `now()`. Days
  pass by moving the waiting rows' clocks back instead: the run's `deadline_at`, the
  invocation's `deadline_at` and `approval_expires_at`, and the task's `due_at`.

  Committed for real, with a real Oban whose queues are paused so each test drains them
  by hand.
  """

  use AshEnterprise.DurabilityCase, async: false

  import AshEnterprise.Test.Execution.Runs
  import Ecto.Query, only: [from: 2]

  require Ash.Query

  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Execution.{Approval, HumanInput}
  alias AshEnterprise.Execution.Invocation
  alias AshEnterprise.Execution.Run
  alias AshEnterprise.Test.DailyFixtures
  alias AshEnterprise.Test.Execution.Intake

  @agent "clinic.intake"
  @ask "human_input_request"
  @sign_off "clinic_note_record_signed_off"

  setup do
    in_zone!()
    pause_queues!()
    clinic = clinic!()
    published!(clinic, %{}, Intake)
    lead = DailyFixtures.member!(clinic.admin, "Clinic lead", [])
    %{clinic: clinic, lead: lead}
  end

  defp unique, do: System.unique_integer([:positive])

  # Every sweep the run and its tool calls have, then every job they enqueue, drained:
  # what a minute of the scheduler does, all of it.
  defp sweep! do
    for scheduler <- [
          Run.StepScheduler,
          Run.RecoverScheduler,
          Invocation.ExecuteScheduler,
          Invocation.ApplyDecisionScheduler,
          Invocation.ReconcileScheduler,
          Invocation.ApplyResolutionScheduler,
          Invocation.CollectInputScheduler
        ],
        do: Oban.insert!(scheduler.new(%{}))

    for queue <- [:execution, :agent_runs, :execution, :agent_runs],
        do: Oban.drain_queue(queue: queue, with_recursion: true)

    :ok
  end

  # The jobs Oban holds, in any state but finished, for the run or any of its
  # invocations.
  defp live_jobs(run) do
    ids = [run.id | Enum.map(invocations(run), & &1.id)]

    Repo.all(
      from(j in Oban.Job,
        where:
          j.state in ["available", "scheduled", "executing", "retryable"] and
            fragment("?->'primary_key'->>'id'", j.args) in ^ids
      )
    )
  end

  # `days` pass for a waiting run: every clock it and its tool calls wait against moves
  # back by that much. Written past the actions, as the clock is.
  defp days_pass!(run, days) do
    ids = Enum.map(invocations(run), & &1.id)
    secs = -days * 86_400

    {1, _} =
      Repo.update_all(
        from(r in "exec_agent_runs",
          where: r.id == type(^run.id, Ecto.UUID),
          update: [
            set: [deadline_at: fragment("? + make_interval(secs => ?)", r.deadline_at, ^secs)]
          ]
        ),
        []
      )

    Repo.update_all(
      from(i in "exec_invocations",
        where: i.id in type(^ids, {:array, Ecto.UUID}),
        update: [
          set: [
            deadline_at: fragment("? + make_interval(secs => ?)", i.deadline_at, ^secs),
            approval_expires_at:
              fragment("? + make_interval(secs => ?)", i.approval_expires_at, ^secs)
          ]
        ]
      ),
      []
    )

    Repo.update_all(
      from(t in "bpmn_human_tasks",
        where: t.subject_id in type(^ids, {:array, Ecto.UUID}),
        update: [set: [due_at: fragment("? + make_interval(secs => ?)", t.due_at, ^secs)]]
      ),
      []
    )

    :ok
  end

  defp task(row, key, tenant) do
    id = row.id

    HumanTask
    |> Ash.Query.filter(subject_id == ^id and node_id == ^key)
    |> Ash.Query.load(:candidates)
    |> Ash.read_one!(authorize?: false, tenant: tenant)
  end

  defp future?(at), do: DateTime.compare(at, DateTime.utc_now()) == :gt

  test "a run waits days for a person's answer with no job, then carries on with it",
       %{clinic: %{nurse: nurse, tenant: tenant}} do
    n = unique()
    question = "SYNTHETIC: which ward is the patient on? #{n}"
    answer = "SYNTHETIC: ward 4B, bed #{n}"

    script!([
      {:tools, [{"call_ask", @ask, %{"input" => %{"question" => question}}}]},
      {:text, ~s({"ward": "4B"})}
    ])

    {:ok, run} = start(nurse, "SYNTHETIC: take the intake for the new referral.", @agent)

    # The first step asks, and the run waits on the question's invocation.
    Oban.drain_queue(queue: :agent_runs)
    assert %{status: :waiting, blocked_on: :tools} = run(run)
    assert [%{status: :ready} = asked] = invocations(run)

    # The question is handed on: the invocation is dispatched, with no lease, and the
    # task for the nurse opened with it, due by the dispatch's deadline.
    Oban.drain_queue(queue: :execution)
    asked = Ash.reload!(asked, authorize?: false, tenant: tenant)

    assert %{status: :dispatched, lease_expires_at: nil} = asked
    assert asked.effect_system == HumanInput.effect_system()

    input_task = task(asked, HumanInput.key(), tenant)
    assert input_task.status == :open
    assert Enum.map(input_task.candidates, & &1.principal_id) == [nurse.user.id]
    assert abs(DateTime.diff(input_task.due_at, asked.deadline_at)) < 60

    # Three days pass. Every sweep runs and finds nothing to do: no job exists for the
    # run or its call, none is executing, and the run has not moved.
    waiting = run(run)
    days_pass!(run, 3)
    sweep!()

    assert live_jobs(run) == []
    assert %{status: :waiting, lease_epoch: epoch, lease_expires_at: nil} = run(run)
    assert epoch == waiting.lease_epoch
    assert future?(run(run).deadline_at)
    assert %{status: :dispatched} = Ash.reload!(asked, authorize?: false, tenant: tenant)
    assert length(model_calls(run)) == 1

    # The nurse answers. The next sweep collects the answer, which wakes the run, and
    # its next step reads the answer and completes.
    assert {:ok, _} =
             HumanTask
             |> Ash.ActionInput.for_action(:answer, %{record_id: input_task.id, answer: answer},
               actor: DailyFixtures.actor(nurse.user),
               tenant: tenant
             )
             |> Ash.run_action()

    sweep!()

    assert %{status: :succeeded, reconciled_via: "human_task"} =
             Ash.reload!(asked, authorize?: false, tenant: tenant)

    assert %{status: :completed} = done = run(run)
    assert Ash.load!(done, [:output], oban(tenant)).output == %{"value" => %{"ward" => "4B"}}
    assert live_jobs(run) == []
    assert length(model_calls(run)) == 2

    assert_received {:model_request, _first, _tools, _opts}
    assert_received {:model_request, second, _tools, _opts}
    assert %{content: parts} = Enum.find(second, &(&1.role == :tool))
    assert Enum.map_join(parts, & &1.text) =~ answer
  end

  test "a run waits days on a four-eyes sign-off with no job, then carries on",
       %{clinic: %{nurse: nurse, tenant: tenant}, lead: lead} do
    n = unique()
    title = "SYNTHETIC: intake note for referral #{n}"

    script!([
      {:tools, [{"call_note", @sign_off, %{"input" => %{"title" => title}}}]},
      {:text, ~s({"recorded": 1})}
    ])

    {:ok, run} = start(nurse, "SYNTHETIC: record the intake note for sign-off.", @agent)
    Oban.drain_queue(queue: :agent_runs)

    assert %{status: :waiting, blocked_on: :tools} = run(run)
    assert [%{status: :awaiting_approval} = call] = invocations(run)
    sign_off = task(call, Approval.key(), tenant)
    assert Enum.map(sign_off.candidates, & &1.principal_id) == [lead.user.id]

    # Two days pass of the three the sign-off may take. Nothing runs, and nothing waits
    # in Oban for the run or its call.
    days_pass!(run, 2)
    sweep!()

    assert live_jobs(run) == []

    assert %{status: :awaiting_approval} =
             call = Ash.reload!(call, authorize?: false, tenant: tenant)

    assert future?(call.approval_expires_at)
    assert run(run).status == :waiting
    assert length(model_calls(run)) == 1

    # The lead signs off. The sweeps apply the decision, run the call, wake the run,
    # and it completes.
    assert {:ok, _} =
             HumanTask
             |> Ash.ActionInput.for_action(:approve, %{record_id: sign_off.id},
               actor: DailyFixtures.actor(lead.user),
               tenant: tenant
             )
             |> Ash.run_action()

    sweep!()

    assert %{status: :succeeded, approved_by_id: approver} =
             Ash.reload!(call, authorize?: false, tenant: tenant)

    assert approver == lead.user.id
    assert %{status: :completed} = done = run(run)
    assert Ash.load!(done, [:output], oban(tenant)).output == %{"value" => %{"recorded" => 1}}
    assert live_jobs(run) == []
  end
end
