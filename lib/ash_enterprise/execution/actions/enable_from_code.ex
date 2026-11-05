defmodule AshEnterprise.Execution.Actions.EnableFromCode do
  @moduledoc """
  `enable_from_code`: the steps that turn an agent declared in code on in the caller's
  tenant, as far as a request, and no further. Idempotent: run it again and it reports
  where things stand instead of asking twice.

    1. **The baseline.** The agent is registered from code into the platform
       organization (`register_from_code` as the `seed` system actor, creating the
       platform organization if this deployment has none yet). The same code writes
       nothing; changed code is the next baseline version.
    2. **The tenant's copy.** `fork_for_tenant`, as the caller: the tenant's latest
       version when it already holds the baseline's content, otherwise a new draft.
    3. **The request.** For a draft, `request_publish` as the caller, unless a request
       to publish that draft is already waiting for approval, which is returned instead.
       A published copy of the current baseline is reported as already published, and
       nothing is asked.

  It never approves the request and never gives anyone a start grant
  (`AshEnterprise.Security.AgentStartGrant`): both stay people's own acts. The result
  says what remains: `outcome` (`"requested"`, `"already_requested"` or
  `"already_published"`), the version, and for a waiting request its `invocation_id`,
  `approval_url` and `self_approval`, whether the caller may approve it themselves under
  the sole-administrator rule (`AshEnterprise.Execution.Approval.sole_administrator?/3`).

  Called through `AshEnterprise.Execution.enable_agent_from_code/2`; from a shell,
  `mix ash_enterprise.assistant.enable`.
  """

  use Ash.Resource.Actions.Implementation
  use AshEnterpriseWeb, :verified_routes

  require Ash.Query

  alias AshAgent.Invocation.Target
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.{Approval, Invocation}
  alias AshEnterprise.Platform.{Seeder, SystemActor}

  @impl true
  def run(input, _opts, context) do
    agent = input.arguments.agent
    opts = Ash.Context.to_opts(context)

    with {:ok, key} <- agent_key(agent),
         {:ok, _baseline} <- register_baseline(agent),
         {:ok, version} <- Execution.fork_agent_for_tenant(key, opts) do
      enable(input.resource, version, opts)
    end
  end

  defp agent_key(agent) do
    case AshAgent.Agent.declaration(agent) do
      {:ok, declaration} -> {:ok, declaration.key}
      {:error, message} -> {:error, invalid(message)}
    end
  end

  # A platform act, not the caller's: the baseline is code, the same for every tenant.
  defp register_baseline(agent) do
    platform = Seeder.seed_platform_organization()

    Execution.register_agent_from_code(agent, actor: SystemActor.seed(), tenant: platform.id)
  end

  defp enable(_resource, %{status: :published} = version, _opts),
    do: {:ok, Map.put(version_fields(version), "outcome", "already_published")}

  defp enable(resource, %{status: :draft} = version, opts) do
    case waiting_request(resource, version, opts[:tenant]) do
      %Invocation{} = row ->
        {:ok, request_fields(version, row, opts, "already_requested")}

      nil ->
        with {:ok, asked} <- Execution.request_agent_publish(version.id, opts) do
          row =
            Execution.get_invocation!(asked["invocation_id"],
              authorize?: false,
              tenant: opts[:tenant]
            )

          {:ok, request_fields(version, row, opts, "requested")}
        end
    end
  end

  defp enable(_resource, %{status: status}, _opts),
    do:
      {:error,
       invalid(
         "the tenant's copy of this agent is #{status}; revise it into a new draft before enabling"
       )}

  # A request to publish this draft that is still waiting, by anyone. Read without
  # authorization (action logic): another administrator's waiting request still means
  # nothing new should be asked. The draft is the request's `identifier` in its
  # authorization details, since its arguments are sealed.
  defp waiting_request(resource, version, tenant) do
    target = Target.name(resource, :apply_publish)
    id = to_string(version.id)

    Invocation
    |> Ash.Query.filter(target == ^target and status == :awaiting_approval)
    |> Ash.Query.sort(created_on: :desc)
    |> Ash.read!(authorize?: false, tenant: tenant)
    |> Enum.find(fn row ->
      Enum.any?(row.authorization_details || [], &(&1["identifier"] == id))
    end)
  end

  defp request_fields(version, row, opts, outcome) do
    requester_id = opts[:actor] && Map.get(opts[:actor], :id)

    version
    |> version_fields()
    |> Map.merge(%{
      "outcome" => outcome,
      "invocation_id" => row.id,
      "status" => Atom.to_string(row.status),
      "error_code" => row.error_code,
      "approval_url" => approval_url(row),
      "self_approval" =>
        row.owner_id == requester_id and
          Approval.sole_administrator?(row.organization_id, requester_id, row.effects)
    })
  end

  defp version_fields(version),
    do: %{"version_id" => version.id, "key" => version.key, "version" => version.version}

  # Only the task's address leaves here, as `request_publish` returns it.
  defp approval_url(%{status: :awaiting_approval} = row) do
    case Ash.load(row, :approval_task, authorize?: false) do
      {:ok, %{approval_task: %{id: id}}} -> url(~p"/app/r/approvals/#{id}")
      _no_task -> nil
    end
  end

  defp approval_url(_row), do: nil

  defp invalid(message),
    do: Ash.Error.Changes.InvalidArgument.exception(field: :agent, message: message)
end
