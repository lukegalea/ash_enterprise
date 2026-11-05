defmodule Battery.Integration.AgentHumanWaitTest do
  @moduledoc """
  Scenario 7 — agent run ↔ process task: a run waits on a person.

  An ash_agent run (`Battery.Execution.Run`, the `AshAgent.Run` fragment on a plain
  resource) calls a tool that asks the person it acts for a question
  (`Battery.Execution.HumanInput`, `intent: :propose`). The tool returns a dispatch, so
  its invocation is `dispatched`, with no lease and a deadline, and the question's
  standalone ash_bpmn `HumanTask` opens in the dispatch's own transaction
  (`AshBpmn.Changes.RequireApproval`, the invocation's owner its only candidate). The
  run waits on the invocation as it waits on any tool call.

  While it waits, days pass (the waiting rows' clocks move back; the battery has no
  clock to move) and every sweep a host runs finds nothing to do: the run has no step
  to take, the invocation nothing to execute or collect, no job exists for either, and
  no model call is made. The person answers through the engine
  (`AshBpmn.complete_task/2`, the answer as its comment); `collect_input` completes the
  invocation with `complete_external`, the answer as its `result`; the run's next step
  reads it as the tool call's result and completes. A withdrawn question fails the
  call, and the run carries on without an answer.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  require Ash.Query

  alias AshAgent.Run.Stepper
  alias Battery.Bpmn.HumanTask
  alias Battery.Execution.{AgentVersion, HumanInput, Intake, Invocation, Member, Run}
  alias Battery.Repo
  alias Battery.ScriptedModel

  @agent "battery.intake"

  # ash_agent asks these for their optional callbacks with function_exported?/3, which
  # is false for a module nothing has loaded yet; both boots (test_helper and
  # `mix platform_battery`) run this.
  setup_all do
    Enum.each([Battery.Execution.Identity, Battery.Execution.Runtime], &Code.ensure_loaded!/1)
    :ok
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

    for table <- ~w(battery_agent_steps battery_invocations battery_agent_runs
                    battery_agent_versions battery_members bpmn_task_candidates
                    bpmn_human_tasks bpmn_process_events) do
      Repo.query!("DELETE FROM " <> table)
    end

    AgentVersion
    |> Ash.ActionInput.for_action(:register_from_code, %{agent: Intake})
    |> Ash.run_action!()
    |> Ash.Changeset.for_update(:apply_publish, %{})
    |> Ash.update!()

    nurse = Ash.create!(Member, %{name: "Dana (nurse)", role: "nurse"})
    colleague = Ash.create!(Member, %{name: "Sam (nurse)", role: "nurse"})
    %{nurse: nurse, colleague: colleague}
  end

  defp unique, do: System.unique_integer([:positive])

  # A run of the intake agent, started by `nurse`, that asked `question` and waits on
  # the answer; its next reply is `reply`.
  defp asked!(nurse, question, reply) do
    ScriptedModel.script!([
      {:tools, [{"call_ask", "human_input_request", %{"input" => %{"question" => question}}}]},
      {:text, reply}
    ])

    run =
      Run
      |> Ash.Changeset.for_create(
        :start,
        %{agent: @agent, input: "SYNTHETIC: take the intake for the new referral."},
        actor: nurse
      )
      |> Ash.create!()

    # The first step asks: the call is requested under the run, and the run waits on it.
    assert {:ok, :waiting} = step(run)
    assert [%{status: :ready} = asked] = invocations(run)
    assert asked.owner_id == nurse.id

    # Executed, the question is handed on, not answered.
    assert execute(asked) == :dispatched
    run
  end

  defp step(run), do: Stepper.step(Run, run.id, [])
  defp current(%Run{} = run), do: Ash.get!(Run, run.id)
  defp current(row), do: Ash.get!(Invocation, row.id)

  defp invocations(run),
    do: Invocation |> Ash.Query.filter(run_id == ^run.id) |> Ash.read!()

  defp execute(row) do
    Invocation
    |> Ash.ActionInput.for_action(:execute, %{primary_key: %{"id" => row.id}})
    |> Ash.run_action!()
  end

  defp collect(row) do
    Invocation
    |> Ash.ActionInput.for_action(:collect_input, %{primary_key: %{"id" => row.id}})
    |> Ash.run_action!()
  end

  defp reconcile(row) do
    Invocation
    |> Ash.ActionInput.for_action(:reconcile, %{primary_key: %{"id" => row.id}})
    |> Ash.run_action!()
  end

  defp task(row) do
    key = HumanInput.key()
    id = row.id

    HumanTask
    |> Ash.Query.filter(subject_id == ^id and node_id == ^key)
    |> Ash.Query.load(:candidates)
    |> Ash.read_one!(authorize?: false)
  end

  defp needs_step?(run), do: Ash.load!(current(run), :needs_step).needs_step

  # The jobs not yet finished whose args name the run or one of its invocations.
  defp live_jobs(run) do
    for id <- [run.id | Enum.map(invocations(run), & &1.id)],
        job <-
          Repo.all(
            from(j in "oban_jobs",
              where:
                j.state in ["available", "scheduled", "executing", "retryable"] and
                  like(fragment("?::text", j.args), ^"%#{id}%"),
              select: j.id
            )
          ),
        do: job
  end

  # `days` pass for the waiting run: the run's deadline, its invocations' deadlines and
  # their tasks' due dates all move back by that much.
  defp days_pass!(run, days) do
    ids = Enum.map(invocations(run), & &1.id)
    secs = -days * 86_400

    {1, _} =
      Repo.update_all(
        from(r in "battery_agent_runs",
          where: r.id == type(^run.id, Ecto.UUID),
          update: [
            set: [deadline_at: fragment("? + make_interval(secs => ?)", r.deadline_at, ^secs)]
          ]
        ),
        []
      )

    Repo.update_all(
      from(i in "battery_invocations",
        where: i.id in type(^ids, {:array, Ecto.UUID}),
        update: [
          set: [deadline_at: fragment("? + make_interval(secs => ?)", i.deadline_at, ^secs)]
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

  defp tool_result(request) do
    %{content: parts} = Enum.find(request.messages, &(&1.role == :tool))
    Enum.map_join(parts, & &1.text)
  end

  test "a run waits days on a person's answer with no job and no model call, then carries on",
       %{nurse: nurse, colleague: colleague} do
    n = unique()
    question = "SYNTHETIC: which ward is the patient on? #{n}"
    answer = "SYNTHETIC: ward 4B, bed #{n}"
    run = asked!(nurse, question, ~s({"ward": "4B"}))
    [asked] = invocations(run)

    # Dispatched: no lease, bounded by its deadline. The task is the engine's, opened
    # with the dispatch, for the nurse alone, due when the deadline passes.
    assert %{status: :dispatched, effect_system: "human_input", lease_expires_at: nil} = asked
    assert %DateTime{} = asked.deadline_at

    input_task = task(asked)
    assert {input_task.status, input_task.instance_id} == {:open, nil}
    assert Enum.map(input_task.candidates, & &1.principal_id) == [nurse.id]
    assert abs(DateTime.diff(input_task.due_at, asked.deadline_at)) < 60

    waiting = current(run)

    assert {waiting.status, waiting.blocked_on, waiting.lease_expires_at} ==
             {:waiting, :tools, nil}

    # Three days pass. Every sweep a host would run finds nothing to do, and nothing
    # is running or waiting to run for the run or its call.
    days_pass!(run, 3)

    refute needs_step?(run)
    assert step(run) == {:ok, :skipped}
    assert execute(asked) == :skipped
    assert collect(asked) == :skipped
    assert reconcile(asked) == :skipped

    assert live_jobs(run) == []
    assert %{status: :waiting, lease_expires_at: nil} = still = current(run)
    assert still.lease_epoch == waiting.lease_epoch
    assert current(asked).status == :dispatched
    assert length(ScriptedModel.requests()) == 1

    # Nobody else answers it.
    assert {:error, _} =
             AshBpmn.complete_task(input_task,
               outcome: :answered,
               comment: "SYNTHETIC: ward 9",
               actor: colleague
             )

    # The nurse answers. Collected, the answer completes the call and is its result;
    # the run now has a step to take, which reads it and completes.
    assert {:ok, _} =
             AshBpmn.complete_task(input_task, outcome: :answered, comment: answer, actor: nurse)

    assert collect(asked) == :succeeded
    done = current(asked)
    assert {done.status, done.reconciled_via} == {:succeeded, "human_task"}
    assert done.result == %{"answer" => answer}
    assert collect(asked) == :skipped

    assert needs_step?(run)
    assert {:ok, :completed} = step(run)
    assert %{status: :completed, output: %{"value" => %{"ward" => "4B"}}} = current(run)

    assert [_first, second] = ScriptedModel.requests()
    assert tool_result(second) =~ answer
    assert live_jobs(run) == []
  end

  test "a withdrawn question fails the call, and the run carries on without an answer",
       %{nurse: nurse} do
    run = asked!(nurse, "SYNTHETIC: which ward? #{unique()}", ~s({"ward": null}))
    [asked] = invocations(run)

    asked
    |> task()
    |> Ash.Changeset.for_update(:cancel, %{})
    |> Ash.update!(authorize?: false)

    assert collect(asked) == :failed

    assert %{
             status: :failed,
             failure_class: :rejected,
             error_code: "input_withdrawn",
             result: nil
           } =
             current(asked)

    assert {:ok, :completed} = step(run)
    assert [_first, second] = ScriptedModel.requests()
    assert tool_result(second) =~ "input_withdrawn"
  end
end
