defmodule AshEnterprise.Process.ServiceInvocation do
  @moduledoc """
  A service task whose action is a declared target, run through its invocation (ADR 0055).

  `AshEnterprise.Process.ActionInvoker` hands an entry that names a target here. The task
  does not call the action: it asks for it with `AshEnterprise.Execution.invoke/4`, so the
  act has one `AshEnterprise.Execution.Invocation` row like any other caller's, with the
  same identity, sealing, typed failure and record of what it answered.

  ## The key, and what a redelivery gets

  The engine gives every execution of a node a key, `{instance_id, token_id, node_id}`,
  the same for each redelivery of that execution (an Oban retry, a claim taken back from a
  worker that died, `AshBpmn.retry_instance/2`) and new for the next one (a loop back to
  the node, another instance of a multi-instance task). The invocation key is that key
  written out, `bpmn:<instance>:<token>:<node>`, and the instance and node are its parent.
  A redelivery asks again under the same key, gets the same row back, and returns what the
  row recorded: the target runs once.

  ## Who it runs as

  The person who started the instance (`started_by_id`), never the platform's `process`
  actor (D5 of ADR 0055). They are rebuilt from their grant rows when the task asks, and
  again when the invocation is claimed, so a person who has lost their role or their
  account since starting the process stops it here. An instance with no starter has no
  one to run as, and the task fails.

  ## What may be named, and how it runs

  Only a target that needs no approval and writes only to this application
  (`approval: :none`, `open_world?: false`): it runs inline, in the advance job that
  reached the node, and the token moves on with its answer. A target that needs an
  approval is a user task in the diagram, not a service task; one that reaches outside
  is a send task and a receive task. `runnable/1` says which, and the registry is
  checked against it when a diagram is published.

  ## What the engine sees

  | The invocation | The engine |
  |---|---|
  | `succeeded` | `{:ok, outputs}`: a generic target's map, or the record it wrote (`resource`, `id`), for the diagram to promote from |
  | `failed`, `failure_class: :business` | `{:error, {:bpmn_error, code, %{"invocation_id" => id}}}`, which an error boundary with that `errorCode` catches |
  | any other final outcome | an error: the node is retried and its instance fails, each retry getting the same answer |
  | not final yet (another worker holds it) | an error, so the node is retried until it is |
  """

  alias AshAgent.Invocation.{Failure, Target}
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Identity
  alias AshEnterprise.Faults
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Process.EngineContext

  @doc """
  Runs the target `{resource, action}` for the service task `ctx` describes, with the
  task's subject as its `"id"` and its declared inputs as the rest of its arguments.
  """
  @spec run({Ash.Resource.t(), atom()}, map()) ::
          {:ok, map()} | {:error, {:bpmn_error, String.t(), map()}} | {:error, term()}
  def run({resource, action}, ctx) do
    name = Target.name(resource, action)
    tenant = EngineContext.tenant(ctx)

    with :ok <- runnable(name),
         {:ok, key, parent} <- position(ctx),
         {:ok, starter} <- starter(ctx[:instance], tenant),
         {:ok, row} <-
           Execution.invoke(name, args(ctx), %{key: key, parent: parent},
             actor: starter,
             tenant: tenant
           ),
         {:ok, row} <- settle(row, tenant) do
      # The invocation is final and the engine has not yet recorded the advance: a worker
      # dying here leaves a redelivery to find the recorded answer.
      Faults.point(:process_invocation_settled)
      answer(row)
    end
  end

  @doc """
  Whether a process may run `target` (`"Resource.action"`) as a service task: it needs no
  approval and reaches nothing outside this application.
  """
  @spec runnable(String.t()) :: :ok | {:error, {:not_a_service_task_target, String.t(), atom()}}
  def runnable(target) do
    case Target.resolve(target) do
      {:ok, %{effect: %{approval: approval}}} when approval != :none ->
        {:error, {:not_a_service_task_target, target, :needs_approval}}

      {:ok, %{effect: %{open_world?: true}}} ->
        {:error, {:not_a_service_task_target, target, :open_world}}

      {:ok, _target} ->
        :ok

      {:error, _message} ->
        {:error, {:not_a_service_task_target, target, :undeclared}}
    end
  end

  @doc "The invocation key of the service task the engine key names: `bpmn:<instance>:<token>:<node>`."
  @spec key({Ash.UUID.t(), Ash.UUID.t(), String.t()}) :: String.t()
  def key({instance_id, token_id, node_id}), do: "bpmn:#{instance_id}:#{token_id}:#{node_id}"

  defp position(%{invocation_key: {instance_id, _token_id, node_id} = engine_key}),
    do:
      {:ok, key(engine_key),
       %{"process_instance_id" => instance_id, "process_node_id" => node_id}}

  defp position(_ctx), do: {:error, :no_invocation_key}

  defp starter(%{started_by_id: id}, tenant) when is_binary(id) do
    case Identity.person_actor(id, tenant) do
      {:ok, actor} -> {:ok, actor}
      {:error, reason} -> {:error, {:starter_has_no_authority, reason}}
    end
  end

  defp starter(_instance, _tenant), do: {:error, {:starter_has_no_authority, :no_starter}}

  defp args(ctx) do
    inputs = if is_map(ctx[:inputs]), do: ctx[:inputs], else: %{}

    case ctx[:subject] do
      %{id: id} -> Map.put(inputs, "id", id)
      _none -> inputs
    end
  end

  # A ready row runs here and now, in this job, as the job runner runs it; any other row
  # is as far as it will get from here (final, or held by another worker).
  defp settle(row, tenant) do
    opts = [actor: SystemActor.oban(), tenant: tenant]

    with {:ok, _outcome} <- execute(row, opts) do
      Execution.get_invocation(row.id, Keyword.put(opts, :load, [:result]))
    end
  end

  defp execute(%{status: :ready, id: id}, opts),
    do: Execution.execute_invocation(%{"id" => id}, opts)

  defp execute(row, _opts), do: {:ok, row.status}

  defp answer(row) do
    case Failure.bpmn(row) do
      :completed ->
        {:ok, outputs(row.result)}

      {:error, {:bpmn_error, code, _}} ->
        {:error, {:bpmn_error, code, %{"invocation_id" => row.id}}}

      {:error, {:incident, class, code}} ->
        {:error, {:invocation_failed, row.id, class, code}}

      :waiting ->
        {:error, {:invocation_not_final, row.id, row.status}}
    end
  end

  defp outputs(%{"value" => value}) when is_map(value), do: value
  defp outputs(result) when is_map(result), do: result
  defp outputs(_none), do: %{}
end
