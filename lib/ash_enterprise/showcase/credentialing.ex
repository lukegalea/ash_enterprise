defmodule AshEnterprise.Showcase.Credentialing do
  @moduledoc """
  The credentialing slice of the showcase (`/app/showcase/credentialing`): what the tour
  reads, and the fault panel's controls.

  ## What the tour reads

  Everything as the viewer, through the application's own reads: the clinic's
  credentials (`credentials/1`), and the activation requests the viewer may see
  (`activations/1`) with what each shows of its governance: its status and outcome, the
  approval digest and whether it is bound to the request, the approval task's address,
  and how many activations the registry took for its credential.

  ## The fault panel

  Each control produces one failure scenario through the application's own paths, never
  a path written for the showcase, and refuses unless the demo flag is on
  (`AshEnterprise.Showcase.fault_controls?/0`):

  | Control | Scenario | What it does |
  |---|---|---|
  | `correct_during_approval/2` | F4 | corrects the credential's expiry date through `Credential.correct`, as a colleague would while its activation waits for approval |
  | `revoke_requester_grant/1` | F5 | removes the coordinator's role assignment through `UserRole.destroy`, as an administrator would before the activation runs |
  | `restore/1` | — | runs the clinic's demo data again (`AshEnterprise.Credentialing.DemoData.populate/1`), which gives the coordinator their role back |
  | `kill_after_registry_accepts/0` | F2 | arms the fault point `:credential_registry_accepted` with `:kill`: the next activation's worker dies after the registry accepted it and before anything was recorded |

  The edit and the revocation stand in for another person's act, so they run as the
  demo data's own actor (`SystemActor.seed/0`), the one that set the clinic up, and the
  audit trail says so.
  """

  require Ash.Query

  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.{Credential, DemoData, Registry}
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Approval
  alias AshEnterprise.Faults
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Showcase

  @activate "AshEnterprise.Credentialing.Credential.activate_credential"
  @kill_point :credential_registry_accepted

  @doc "The governed target the slice is about."
  @spec target() :: String.t()
  def target, do: @activate

  @doc "The fault point the kill control arms."
  @spec kill_point() :: atom()
  def kill_point, do: @kill_point

  @doc "The clinic's credentials `actor` may read, with their clinicians, by number."
  @spec credentials(term()) :: [Credential.t()]
  def credentials(actor) do
    Credentialing.list_credentials!(
      actor: actor,
      tenant: ActorContext.tenant(actor),
      load: [:clinician],
      query: [sort: [number: :asc]]
    )
  end

  @doc """
  The activation requests `actor` may read, newest first, each as
  `%{invocation:, credential_id:, bound?:, task_id:, registry_activations:}`.
  """
  @spec activations(term()) :: [map()]
  def activations(actor) do
    tenant = ActorContext.tenant(actor)

    rows =
      Execution.list_invocations!(
        actor: actor,
        tenant: tenant,
        query: [filter: [target: @activate], sort: [created_on: :desc]]
      )

    tasks = approval_tasks(rows, tenant)

    Enum.map(rows, fn row ->
      credential_id = credential_id(row)

      %{
        invocation: row,
        credential_id: credential_id,
        bound?: bound?(row),
        task_id: Map.get(tasks, row.id),
        registry_activations: if(credential_id, do: Registry.activations(credential_id), else: 0)
      }
    end)
  end

  @doc """
  Whether `row`'s approval binds exactly this request: its `approval_digest` is the
  digest of its `authorization_details` (RFC 9396), and those name the row's own target,
  target digest and argument digest (ADR 0055, "Approval binding"). `nil` for a row that
  needs no approval.
  """
  @spec bound?(Execution.Invocation.t()) :: boolean() | nil
  def bound?(%{approval_digest: nil}), do: nil

  def bound?(row) do
    case row.authorization_details do
      [
        %{
          "type" => "urn:ash-agent:action:" <> target,
          "target_digest" => target_digest,
          "args_digest" => args_digest
        }
      ] = details ->
        AshAgent.Invocation.Approval.digest(details) == row.approval_digest and
          {target, target_digest, args_digest} == {row.target, row.target_digest, row.args_digest}

      _other ->
        false
    end
  end

  # The approval task's id per invocation. Read without authorization, as
  # `RequestInvocation` reads it: the requester may not read a task they are excluded
  # from deciding, and only its address leaves here.
  defp approval_tasks([], _tenant), do: %{}

  defp approval_tasks(rows, tenant) do
    ids = Enum.map(rows, & &1.id)
    key = Approval.key()

    HumanTask
    |> Ash.Query.filter(subject_id in ^ids and node_id == ^key)
    |> Ash.Query.select([:id, :subject_id])
    |> Ash.read!(authorize?: false, tenant: tenant)
    |> Map.new(&{&1.subject_id, &1.id})
  end

  defp credential_id(%{preconditions: [%{"id" => id} | _]}), do: id
  defp credential_id(_row), do: nil

  # --- the fault panel -------------------------------------------------------------

  @doc "F2: the next activation's worker is killed after the registry accepted it."
  @spec kill_after_registry_accepts() :: :ok | {:error, :fault_controls_off}
  def kill_after_registry_accepts do
    with :ok <- on(), do: Faults.arm(@kill_point, :kill)
  end

  @doc "F4: a colleague corrects the credential's expiry date while it waits for approval."
  @spec correct_during_approval(Ash.UUID.t(), Ash.UUID.t()) ::
          {:ok, Credential.t()} | {:error, term()}
  def correct_during_approval(credential_id, tenant) do
    opts = [actor: SystemActor.seed(), tenant: tenant]

    with :ok <- on(),
         {:ok, credential} <- Credentialing.get_credential(credential_id, opts) do
      expires_on = Date.add(credential.expires_on || Date.utc_today(), 1)
      Credentialing.correct_credential(credential, %{expires_on: expires_on}, opts)
    end
  end

  @doc """
  F5: an administrator removes the coordinator's credentialing role before their
  activation runs. Returns how many assignments were removed.
  """
  @spec revoke_requester_grant(Ash.UUID.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def revoke_requester_grant(tenant) do
    opts = [actor: SystemActor.seed(), tenant: tenant]
    email = DemoData.coordinator_email()
    role = DemoData.coordinator_role()

    with :ok <- on(),
         {:ok, assignments} <-
           Security.UserRole
           |> Ash.Query.filter(user.email == ^email and role.name == ^role)
           |> Ash.read(opts) do
      destroy_all(assignments, opts)
    end
  end

  defp destroy_all(assignments, opts) do
    Enum.reduce_while(assignments, {:ok, 0}, fn assignment, {:ok, count} ->
      case Ash.destroy(assignment, opts) do
        :ok -> {:cont, {:ok, count + 1}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @doc "Runs the clinic's demo data again, which restores the coordinator's role."
  @spec restore(Ash.UUID.t()) :: {:ok, map()} | {:error, :fault_controls_off}
  def restore(tenant) do
    with :ok <- on(), do: {:ok, DemoData.populate(tenant)}
  end

  defp on, do: if(Showcase.fault_controls?(), do: :ok, else: {:error, :fault_controls_off})
end
