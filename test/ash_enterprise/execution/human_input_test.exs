defmodule AshEnterprise.Execution.HumanInputTest do
  @moduledoc """
  An agent asks a person (`AshEnterprise.Execution.HumanInput`, ADR 0056): the question's
  invocation is dispatched with a task for the person the run acts for; only they answer
  it, only through `HumanTask.answer`; the `:collect_input` trigger completes the call
  from the task, and the run carries on with what it learned: the answer, a withdrawn
  question, or a deadline that passed.

  Sandbox; jobs are drained by hand. The model is the scripted one.
  """

  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  import AshEnterprise.Test.Execution.Runs

  require Ash.Query

  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.{Approval, HumanInput}
  alias AshEnterprise.Execution.Invocation.CollectInputScheduler
  alias AshEnterprise.Test.DailyFixtures
  alias AshEnterprise.Test.Execution.{Durable, Intake}

  @agent "clinic.intake"

  setup do
    in_zone!()
    clinic = clinic!()
    published!(clinic, %{}, Intake)
    %{clinic: clinic}
  end

  # A run of the intake agent that asked the nurse `question` and waits on the answer;
  # its next reply is `reply`.
  defp asked!(%{nurse: nurse, tenant: tenant}, reply) do
    question = "SYNTHETIC: which ward is the patient on? #{System.unique_integer([:positive])}"

    script!([
      {:tools, [{"call_ask", "human_input_request", %{"input" => %{"question" => question}}}]},
      {:text, reply}
    ])

    {:ok, run} = start(nurse, "SYNTHETIC: take the intake.", @agent)
    assert %{success: 1} = Oban.drain_queue(queue: :agent_runs)
    assert_receive {:model_request, _messages, tools, _opts}
    assert "human_input_request" in tools

    assert %{failure: 0} = Oban.drain_queue(queue: :execution)
    [asked] = invocations(run)
    assert asked.status == :dispatched

    %{run: run, asked: asked, task: task(asked, HumanInput.key(), tenant)}
  end

  defp task(row, key, tenant) do
    id = row.id

    HumanTask
    |> Ash.Query.filter(subject_id == ^id and node_id == ^key)
    |> Ash.read_one!(authorize?: false, tenant: tenant)
  end

  defp door(action, task, person, input \\ %{}) do
    HumanTask
    |> Ash.ActionInput.for_action(action, Map.put(input, :record_id, task.id),
      actor: DailyFixtures.actor(person.user),
      tenant: task.organization_id
    )
    |> Ash.run_action()
  end

  defp collect! do
    Oban.insert!(CollectInputScheduler.new(%{}))
    assert %{failure: 0} = Oban.drain_queue(queue: :execution, with_recursion: true)
  end

  defp tool_result do
    assert_receive {:model_request, messages, _tools, _opts}
    %{content: parts} = Enum.find(messages, &(&1.role == :tool))
    Enum.map_join(parts, & &1.text)
  end

  test "the person the run acts for answers; the answer is the call's result",
       %{clinic: clinic} do
    %{run: run, asked: asked, task: task} = asked!(clinic, ~s({"ward": "4B"}))

    assert task.status == :open
    assert task.subject_type == to_string(Execution.Invocation)
    assert %DateTime{} = task.due_at

    # Nobody else answers it: not even the administrator.
    assert {:error, _} = door(:answer, task, clinic.admin, %{answer: "SYNTHETIC: ward 9"})
    assert task(asked, HumanInput.key(), clinic.tenant).status == :open

    # Until the nurse answers, there is nothing to collect and no step to take.
    collect!()
    assert run(run).status == :waiting
    refute_enqueued(worker: AshEnterprise.Execution.Run.StepWorker)

    assert {:ok, _} = door(:answer, task, clinic.nurse, %{answer: "SYNTHETIC: ward 4B"})
    collect!()

    done = Execution.get_invocation!(asked.id, oban(clinic.tenant))
    assert {done.status, done.reconciled_via} == {:succeeded, "human_task"}

    assert Ash.load!(done, [:result], oban(clinic.tenant)).result == %{
             "answer" => "SYNTHETIC: ward 4B"
           }

    assert %{success: 1} = Oban.drain_queue(queue: :agent_runs)
    assert tool_result() =~ "SYNTHETIC: ward 4B"
    assert run(run).status == :completed
  end

  test "an agent's question is answered only through answer, and answer answers nothing else",
       %{clinic: clinic} do
    %{task: task} = asked!(clinic, ~s({"ward": null}))

    for action <- [:approve, :reject] do
      assert {:error, error} = door(action, task, clinic.nurse)
      assert Exception.message(error) =~ "answer it"
    end

    # An approval task is not a question.
    lead = DailyFixtures.member!(clinic.admin, "Clinic lead", [])

    {:ok, row} =
      Execution.invoke(
        "AshEnterprise.Test.Execution.ClinicNote.record_signed_off",
        %{"title" => "SYNTHETIC: a note for sign-off"},
        %{key: "sign-off:#{System.unique_integer([:positive])}"},
        actor: clinic.nurse.actor,
        tenant: clinic.tenant
      )

    approval = task(row, Approval.key(), clinic.tenant)

    assert {:error, error} = door(:answer, approval, lead, %{answer: "SYNTHETIC: yes"})
    assert Exception.message(error) =~ "only an agent's question is answered"
    assert task(row, Approval.key(), clinic.tenant).status == :open
  end

  test "a withdrawn question fails the call; the run carries on without an answer",
       %{clinic: clinic} do
    %{run: run, asked: asked, task: task} = asked!(clinic, ~s({"ward": null}))

    task
    |> Ash.Changeset.for_update(:cancel, %{})
    |> Ash.update!(authorize?: false, tenant: clinic.tenant)

    collect!()

    assert %{status: :failed, failure_class: :rejected, error_code: "input_withdrawn"} =
             Execution.get_invocation!(asked.id, oban(clinic.tenant))

    assert %{success: 1} = Oban.drain_queue(queue: :agent_runs)
    assert tool_result() =~ "input_withdrawn"
    assert run(run).status == :completed
  end

  test "a question nobody answers by its deadline fails as a timeout", %{clinic: clinic} do
    %{run: run, asked: asked} = asked!(clinic, ~s({"ward": null}))

    :ok = Durable.elapse!(asked, :deadline_at)
    assert :failed = Execution.reconcile_invocation!(%{"id" => asked.id}, oban(clinic.tenant))

    assert %{status: :failed, failure_class: :timeout, error_code: "deadline_passed"} =
             Execution.get_invocation!(asked.id, oban(clinic.tenant))

    assert %{success: 1} = Oban.drain_queue(queue: :agent_runs)
    assert tool_result() =~ "deadline_passed"
    assert run(run).status == :completed
  end

  test "a question is asked only through a run's tool call", %{clinic: clinic} do
    assert {:error, error} =
             HumanInput
             |> Ash.ActionInput.for_action(:request, %{question: "SYNTHETIC: anyone?"},
               actor: clinic.nurse.actor
             )
             |> Ash.run_action()

    assert Exception.message(error) =~ "through a run's tool call"
  end
end
