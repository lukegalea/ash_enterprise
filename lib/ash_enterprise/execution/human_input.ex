defmodule AshEnterprise.Execution.HumanInput do
  @moduledoc """
  An agent asks a person (ADR 0056, "Waiting on a person"): the `human_input_request` tool.

  A run's call to this tool is an invocation like any other tool call that is not an
  in-loop read, so "the agent waits on a person" is the same wait as "the agent waits on
  a tool". The target, `request`, does nothing itself: it hands the question on
  (`AshAgent.Invocation.Dispatch`, `effect_system` `"human_input"`), and the invocation
  becomes `dispatched`. In that same transaction a standalone `HumanTask` opens for the
  person the run acts for (`AshEnterprise.Execution.Changes.OpenInputTask`), due by the
  dispatch's deadline, `answer_within/0` from now.

  While the person has not answered, nothing runs: the invocation is `dispatched` with
  no lease and no job, and the run is `waiting` with no step to take (`needs_step` is
  false while one of its invocations is open), so no sweep picks either up. A wait of
  days costs rows, not a process.

  The person answers through `HumanTask.answer`, the only door that completes an input
  task (`check/2`). The `:collect_input` trigger on the invocation then completes it
  with `complete_external`, the answer as its `result`
  (`AshEnterprise.Execution.Actions.CollectInput`); that wakes the run, whose next step
  reads the answer as the tool call's result. A task cancelled before it is answered
  fails the call as `:rejected`, `"input_withdrawn"`. A question nobody answers by the
  deadline fails as `:timeout`, `"deadline_passed"`: the engine closes its task as
  expired then, so nobody answers into a wait that has ended, and the `:reconcile`
  sweep fails a dispatch whose deadline passed in any case.

  Self-service (ADR 0052): any member may ask, through their own run.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Execution,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    self_service: [:request],
    extra_extensions: [AshAgent.Effects]

  @effect_system "human_input"
  @key "invocation.input"
  @answer_within [days: 7]

  resource do
    require_primary_key? false
  end

  # Asking writes nothing outside this application (the task opens with the dispatch,
  # in its transaction), and asking again under the same invocation opens no second
  # task, so a deadline that passes fails the call rather than leaving it in doubt.
  effects do
    action :request,
      kind: :other,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :propose
  end

  actions do
    action :request, :struct do
      description """
      Ask the person you act for a question, and wait for their answer. Use it when you
      need something only they know; the run waits until they answer.
      """

      constraints instance_of: AshAgent.Invocation.Dispatch

      argument :question, :string do
        allow_nil? false
        constraints max_length: 2000
        description "The question, as the person will read it."
      end

      run AshEnterprise.Execution.Actions.RequestHumanInput
    end
  end

  @doc "The `effect_system` a dispatched question is recorded under."
  @spec effect_system() :: String.t()
  def effect_system, do: @effect_system

  @doc "The standalone task key an input task is opened under."
  @spec key() :: String.t()
  def key, do: @key

  @doc "How long a person has to answer."
  @spec answer_within() :: keyword()
  def answer_within, do: @answer_within

  @doc "Whether `task` is an input task."
  @spec task?(struct()) :: boolean()
  def task?(%{node_id: @key, instance_id: nil}), do: true
  def task?(_task), do: false

  @doc """
  Whether `task` may be completed through `door`: `:answer` (the `HumanTask.answer`
  action) for an input task only, any other door for every other task.
  """
  @spec check(struct(), atom()) :: :ok | {:error, String.t()}
  def check(task, :answer) do
    if task?(task), do: :ok, else: {:error, "only an agent's question is answered"}
  end

  def check(task, _door) do
    if task?(task), do: {:error, "this task is an agent's question: answer it"}, else: :ok
  end
end
