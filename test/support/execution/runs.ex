defmodule AshEnterprise.Test.Execution.Runs do
  @moduledoc """
  Helpers the agent run tests share: a clinic with an administrator, a second
  administrator to approve publishing and a nurse who holds no role; the note-taking
  agent (`AshEnterprise.Test.Execution.NoteTaker`) published in it under four eyes; and
  model calls routed to `AshEnterprise.Test.AssistantFixtures.ScriptedModel` behind the
  guarded ReqLLM module, so every call is still guarded and recorded and none reaches a
  network.

  Works in the sandbox and in the durability tier alike. Every helper keys what it reads
  by the tenant or the run a test created.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]
  import Ecto.Query, only: [from: 2]

  require Ash.Query

  alias AshAgent.Invocation.Executor
  alias AshEnterprise.AI.ModelCall
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.{AgentRuntime, Invocation}
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Test.AssistantFixtures
  alias AshEnterprise.Test.AssistantFixtures.ScriptedModel
  alias AshEnterprise.Test.Execution.{Authority, NoteTaker}

  @agent "clinic.note_taker"
  @tool "clinic_note_record"

  @doc "The note-taking agent's key."
  def agent, do: @agent

  @doc """
  A clinic: `%{admin:, approver:, nurse:, tenant:}`. The administrator and the approver
  hold the tenant's Administrator role; the nurse holds none.
  """
  def clinic! do
    admin = AssistantFixtures.tenant!()

    %{
      admin: admin,
      approver: AssistantFixtures.colleague!(admin, admin?: true),
      nurse: AssistantFixtures.colleague!(admin, []),
      tenant: admin.tenant
    }
  end

  @doc """
  Configures the in-zone profile and routes every run's model calls to the scripted
  model. Restored on exit.
  """
  def in_zone! do
    :ok = AssistantFixtures.in_zone!()
    previous = Application.get_env(:ash_enterprise, AgentRuntime)

    Application.put_env(:ash_enterprise, AgentRuntime, req_llm_opts: [downstream: ScriptedModel])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ash_enterprise, AgentRuntime, previous),
        else: Application.delete_env(:ash_enterprise, AgentRuntime)
    end)
  end

  @doc "The script the model follows, as `ScriptedModel.script!/1` takes it."
  def script!(replies), do: ScriptedModel.script!(replies)

  @doc """
  Publishes the note-taking agent in `clinic`: registered from code, asked for by the
  administrator, approved by the approver, applied and run as the job runner runs it.
  The nurse is given its start grant. `choice` is what the publish request asks for
  (`authority:`, `requesterless:`).
  """
  def published!(clinic, choice \\ %{}) do
    %{admin: admin, approver: approver, tenant: tenant} = clinic
    draft = Execution.register_agent_from_code!(NoteTaker, actor: admin.actor, tenant: tenant)

    %{"invocation_id" => id} =
      Execution.request_agent_publish!(draft.id, choice, actor: admin.actor, tenant: tenant)

    row = Execution.get_invocation!(id, authorize?: false, tenant: tenant)
    task = Ash.load!(row, :approval_task, authorize?: false).approval_task

    HumanTask
    |> Ash.ActionInput.for_action(:approve, %{record_id: task.id},
      actor: approver.actor,
      tenant: tenant
    )
    |> Ash.run_action!()

    %{status: :ready} = Execution.apply_invocation_decision!(row, oban(tenant))
    {:ok, :succeeded} = Executor.execute(Invocation, row.id, oban(tenant))
    Authority.start_grant!(admin, clinic.nurse, @agent)

    Execution.get_agent_version!(draft.id, authorize?: false, tenant: tenant)
  end

  @doc "Options for the job runner in `tenant`: how the machinery reads and writes rows."
  def oban(tenant), do: [actor: SystemActor.oban(), tenant: tenant]

  @doc "`member` starts a run of the note-taking agent, asked `input`."
  def start(member, input \\ "SYNTHETIC: record the notes the clinician dictates.") do
    Execution.start_agent_run(@agent, input, actor: member.actor, tenant: member.tenant)
  end

  @doc "A model's call to record a note titled `title`, with the call id `id`."
  def record_call(id, title), do: {id, @tool, %{"input" => %{"title" => title}}}

  @doc "The run as committed now."
  def run(run), do: Execution.get_agent_run!(run.id, oban(run.organization_id))

  @doc "Takes one step of `run`, as its `:step` job does."
  def step!(run),
    do: Execution.step_agent_run!(%{"id" => run.id}, oban(run.organization_id))

  @doc "The run's journal, in order: `{seq, role}`."
  def journal(run) do
    id = run.id

    Execution.list_agent_steps!(
      query: [filter: [run_id: id], sort: [seq: :asc]],
      authorize?: false,
      tenant: run.organization_id
    )
    |> Enum.map(&{&1.seq, &1.role})
  end

  @doc "The run's tool-call invocations, by key."
  def invocations(run) do
    id = run.id

    Execution.list_invocations!(
      query: [filter: [run_id: id], sort: [invocation_key: :asc]],
      authorize?: false,
      tenant: run.organization_id
    )
  end

  @doc "The model calls recorded for `run`, oldest first: `{caller, outcome}`."
  def model_calls(run) do
    prefix = "run:#{run.id}:"

    ModelCall
    |> Ash.Query.filter(contains(caller, ^prefix))
    |> Ash.Query.sort(created_on: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.map(&{&1.caller, &1.outcome})
  end

  @doc """
  Time passes for `run`: its lease ran out a minute ago, as when the worker holding it
  died. Written past the actions, as the clock is.
  """
  def elapse_lease!(run) do
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    {1, _} =
      AshEnterprise.Repo.update_all(
        from(r in "exec_agent_runs", where: r.id == type(^run.id, Ecto.UUID)),
        set: [lease_expires_at: past]
      )

    :ok
  end

  @doc "The `:step` jobs waiting to run for `run`."
  def step_jobs(run) do
    worker = inspect(AshEnterprise.Execution.Run.StepWorker)

    AshEnterprise.Repo.all(
      from(j in Oban.Job,
        where:
          j.worker == ^worker and j.state in ["available", "scheduled", "retryable"] and
            fragment("?->'primary_key'->>'id' = ?", j.args, ^run.id)
      )
    )
  end

  @doc """
  Stops the `:agent_runs` and `:execution` queues for the rest of the test, so a test
  drives every step and invocation itself. Jobs the test left behind are cancelled
  before the queues resume.
  """
  def pause_queues! do
    for queue <- [:agent_runs, :execution], do: :ok = Oban.pause_queue(queue: queue)

    on_exit(fn ->
      Oban.cancel_all_jobs(from(j in Oban.Job, where: j.queue in ["agent_runs", "execution"]))
      for queue <- [:agent_runs, :execution], do: Oban.resume_queue(queue: queue)
    end)
  end
end
