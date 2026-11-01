defmodule AshEnterprise.Execution.Actions.ConfirmInvocation do
  @moduledoc """
  A person's own act on a governed target (ADR 0055, ADR 0061): the click on a judgment
  surface that certifies a band table or revokes a certification.

      action :certify_now, :map do
        argument :record_id, :uuid, allow_nil?: false
        run {AshEnterprise.Execution.Actions.ConfirmInvocation,
             target: :certify_and_publish, key: "certify", argument: :record_id}
      end

  A governed target has no door but `AshEnterprise.Execution.invoke/4`, so the click goes
  through it too, in four steps that the machinery otherwise spreads over its triggers:

    1. `invoke` the target as the person, for the key `<key>:<click id>`. The key is per
       click, so a refusal the person then fixes (a draft to publish first, a verifier
       finding) can be tried again; an agent's request for the same record is a different
       row, under `<key>:<record id>`.
    2. If the row waits for approval and the person is one of its candidates (they hold
       the target's `approver_role`), they approve its task through `HumanTask.approve`,
       the same door anyone approving it uses. `confirm` lets the requester be the
       approver: the click is the confirmation. A person who is not a candidate leaves
       the request waiting, and gets its approval link.
    3. The `apply_decision` step the trigger would run, as the job runner.
    4. The `execute` step the trigger would run, as the job runner: the row is claimed,
       the person is rebuilt from their grants, and the target runs as them.

  A target that refuses (`AshAgent.BusinessError`, a verifier, a policy) fails the
  invocation, and the click returns its error code.

  Steps 2 to 4 are `confirm/3`, for a caller that already holds the row (an ACP
  permission request the person allowed, `AshEnterprise.Acp.Approvals`), and
  `decline/3` is their counterpart: the person rejects the task, and the decision is
  applied. The person approves or rejects as they are now: their `ActorContext` is
  built afresh, so a task opened since their request began is one they may decide.

  It returns the request as `AshEnterprise.Execution.Actions.RequestInvocation` does:
  `invocation_id`, `target`, `status`, `error_code`, `approval_url`.
  """

  use Ash.Resource.Actions.Implementation
  use AshEnterpriseWeb, :verified_routes

  alias AshAgent.Invocation.{Executor, Target}
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.{Identity, Invocation}
  alias AshEnterprise.Platform.SystemActor

  @impl true
  def run(input, opts, context) do
    target = Target.name(input.resource, Keyword.fetch!(opts, :target))
    id = input.arguments.record_id
    args = %{(opts |> Keyword.fetch!(:argument) |> to_string()) => id}
    key = "#{Keyword.fetch!(opts, :key)}:#{id}:click:#{Ash.UUIDv7.generate()}"
    ash_opts = Ash.Context.to_opts(context)
    tenant = ash_opts[:tenant]

    with {:ok, row} <- Execution.invoke(target, args, %{key: key}, ash_opts),
         {:ok, row} <- confirm(row, context.actor, tenant) do
      report(row)
    end
  end

  @doc """
  The person confirms `row`, their own request: if it waits for approval and they are a
  candidate, they approve its task, the decision is applied and the ready row runs, all
  now. Returns the row as it then stands; a person who is not a candidate leaves it
  waiting.
  """
  @spec confirm(Ash.Resource.record(), Ash.Resource.record(), Ash.UUID.t()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def confirm(%{status: :awaiting_approval} = row, actor, tenant) do
    runner = [actor: SystemActor.oban(), tenant: tenant]

    case decide(row, :approve, actor, tenant) do
      :ok ->
        with {:ok, row} <- Execution.apply_invocation_decision(row, runner),
             {:ok, _outcome} <- run_ready(row, runner) do
          Execution.get_invocation(row.id, runner)
        end

      :not_a_candidate ->
        {:ok, row}

      {:error, error} ->
        {:error, error}
    end
  end

  def confirm(row, _actor, _tenant), do: {:ok, row}

  @doc """
  The person declines `row`, their own request waiting for approval: they reject its
  task and the decision is applied now, so the row is `rejected` and nothing runs.
  """
  @spec decline(Ash.Resource.record(), Ash.Resource.record(), Ash.UUID.t()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def decline(%{status: :awaiting_approval} = row, actor, tenant) do
    case decide(row, :reject, actor, tenant) do
      :ok -> Execution.apply_invocation_decision(row, actor: SystemActor.oban(), tenant: tenant)
      :not_a_candidate -> {:ok, row}
      {:error, error} -> {:error, error}
    end
  end

  def decline(row, _actor, _tenant), do: {:ok, row}

  defp run_ready(%{status: :ready} = row, runner),
    do: Executor.execute(Invocation, row.id, runner)

  defp run_ready(_row, _runner), do: {:ok, :skipped}

  # As the person they are now: a context built at the start of their request does not
  # know the task the request itself opened.
  defp decide(row, door, actor, tenant) do
    %{approval_task: %{id: task_id}} = Ash.load!(row, :approval_task, authorize?: false)

    with {:ok, person} <-
           Identity.actor_for(%{
             executing_principal: %{type: :person, id: actor.id},
             organization_id: tenant
           }) do
      HumanTask
      |> Ash.ActionInput.for_action(door, %{record_id: task_id}, actor: person, tenant: tenant)
      |> Ash.run_action()
      |> decision()
    end
  end

  defp decision({:ok, _decided}), do: :ok

  defp decision({:error, error}),
    do: if(candidate_refusal?(error), do: :not_a_candidate, else: {:error, error})

  # Not holding the approver role reads as a refusal or an empty read of the task. Any other
  # failure (a stale task, a database error) is a real one and fails the click.
  defp candidate_refusal?(%Ash.Error.Forbidden{}), do: true

  defp candidate_refusal?(%Ash.Error.Invalid{errors: errors}),
    do: errors != [] and Enum.all?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))

  defp candidate_refusal?(_other), do: false

  defp report(%{status: status} = row) when status in [:failed, :rejected, :stale] do
    {:error,
     "The request #{status}#{if row.error_code, do: ": " <> row.error_code, else: ""}. " <>
       "Nothing was changed."}
  end

  defp report(row) do
    {:ok,
     %{
       "invocation_id" => row.id,
       "target" => row.target,
       "status" => Atom.to_string(row.status),
       "error_code" => row.error_code,
       "approval_url" => approval_url(row)
     }}
  end

  defp approval_url(%{status: :awaiting_approval} = row) do
    case Ash.load(row, :approval_task, authorize?: false) do
      {:ok, %{approval_task: %{id: id}}} -> url(~p"/app/r/approvals/#{id}")
      _no_task -> nil
    end
  end

  defp approval_url(_row), do: nil
end
